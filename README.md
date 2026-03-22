# aws-secure-eks-platform

Production-grade EKS cluster built on a zero-trust security model. Every pod has its own AWS identity via IRSA. All pod-to-pod traffic is denied by default via Calico GlobalNetworkPolicy. Nodes never touch the public internet for image pulls or credential renewal. Karpenter handles node autoscaling in under 60 seconds. The full observability stack ships as code.

This is not a tutorial cluster. Every design decision has a documented trade-off and a reason it was chosen over the alternative.

---

## The problem this solves

Most EKS clusters in production have three silent security problems: nodes use instance profiles so a single compromised pod inherits the AWS permissions of every other pod on that node; container image pulls go through NAT and fail when the NAT Gateway has an incident; and network policy is either absent or so permissive it provides no real isolation. This platform fixes all three from day one.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  VPC 10.0.0.0/16                                                │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│  │  Public /24  │  │  Public /24  │  │  Public /24  │         │
│  │  ALB · NAT   │  │  ALB · NAT   │  │  ALB · NAT   │         │
│  └──────────────┘  └──────────────┘  └──────────────┘         │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│  │ Private /24  │  │ Private /24  │  │ Private /24  │         │
│  │ Nodes · /28  │  │ Nodes · /28  │  │ Nodes · /28  │         │
│  │ prefix delg  │  │ prefix delg  │  │ prefix delg  │         │
│  └──────────────┘  └──────────────┘  └──────────────┘         │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│  │ Isolated /24 │  │ Isolated /24 │  │ Isolated /24 │         │
│  │  Data tier   │  │  Data tier   │  │  Data tier   │         │
│  └──────────────┘  └──────────────┘  └──────────────┘         │
│                                                                 │
│  VPC Endpoints: s3 (gw) · dynamodb (gw) · ecr.dkr · ecr.api  │
│                 sts · secretsmanager · logs · monitoring        │
└─────────────────────────────────────────────────────────────────┘

EKS Control Plane (AWS-managed VPC)
  └── authentication_mode: API  (EKS Access Entries, not aws-auth)
  └── OIDC provider → pod-identity-webhook (regional STS enforced)

Node Groups
  ├── system-ng:   2× t3.medium · AL2023 · tainted CriticalAddonsOnly
  │     Runs: Karpenter · kube-prometheus-stack · CoreDNS · add-ons
  └── karpenter:   EC2NodeClass → AL2023 pinned AMI digest
        NodePool:  m5/m5a/m5n/m6i · On-Demand 40% · Spot 60%
        Scale-up:  ~55s via EC2 Fleet API

Pod Security
  ├── Calico CNI (chained mode, cni.type: AmazonVPC)
  │     GlobalNetworkPolicy order 9000: default deny all
  │     Named policies order 100-400: explicit allow only
  │     DNS allow: label-scoped to k8s-app=kube-dns only
  ├── PSS Restricted enforced on all application namespaces
  ├── IRSA: StringEquals trust policy, oidc:sub + oidc:aud conditions
  └── IMDSv2: http_tokens=required, hop_limit=2, IMDSv1 disabled

Observability (monitoring namespace, system-ng only)
  ├── kube-prometheus-stack via Helm (storageSpec: gp3 50Gi PVC)
  ├── 5 custom PrometheusRule resources
  ├── Grafana dashboards as ConfigMaps (grafana_dashboard: "1")
  ├── Grafana credentials: External Secrets → Secrets Manager
  └── AlertManager: group_wait 30s · Watchdog dead man's switch

Security Scanning
  └── GuardDuty EKS Protection (runtime threat detection)
  └── CloudTrail (all API calls, integrity validation)
  └── CW Logs IA class: api + audit + authenticator types only
```

---

## Design decisions

### IRSA over node instance profiles

With instance profiles, every pod on a node inherits the node role. One compromised pod gets every permission assigned to any other workload on that node. IRSA binds a role to a specific ServiceAccount via a projected OIDC token. The trust policy uses `StringEquals` on both `oidc:sub` and `oidc:aud` — not `StringLike`, which would allow any ServiceAccount in the namespace to assume the role.

The STS VPC endpoint is not cosmetic. IRSA credentials expire and renew via STS every hour. In a private subnet with no STS endpoint, credential renewal calls the global `sts.amazonaws.com` endpoint in us-east-1. Real clusters lost AWS access during us-east-1 incidents because of this. The endpoint alone is not enough — the pod-identity-webhook must be configured with `--sts-regional-endpoint=true` to inject `AWS_STS_REGIONAL_ENDPOINTS=regional` into every IRSA-enabled pod. Without this flag the VPC endpoint is bypassed regardless.

**Trade-off vs EKS Pod Identity:** Pod Identity is simpler to configure and is AWS's current recommended approach for new workloads. It is not used here because the AWS Load Balancer Controller, the VPC CNI (aws-node), and the EBS CSI Driver cannot use Pod Identity. Maintaining two different identity mechanisms in the same cluster adds more operational complexity than consistent IRSA across all workloads.

### Calico in chained mode, not BYOCNI

Calico runs alongside the AWS VPC CNI rather than replacing it. The operator Installation CR specifies `spec.cni.type: AmazonVPC`. Setting this to `Calico` switches to BYOCNI mode and leaves all nodes `NotReady` until the Calico IPAM pool is configured — a silent failure that is hard to diagnose. Chained mode means Calico handles policy enforcement only, and the VPC CNI continues to manage pod IP allocation via ENIs.

`ANNOTATE_POD_IP=true` is set on the aws-node DaemonSet. This requires adding pod patch permissions to the aws-node ClusterRole — a documented RBAC escalation on a `hostNetwork` DaemonSet. The trade-off is accepted: without it, a Kubernetes race condition causes pod IP annotation failures under Calico policy enforcement in chained mode.

Topology Aware Routing is not used. TAR applies hard zone isolation: when pods in a zone fail, traffic from that zone cannot reach healthy pods in other zones. A real production failure showed 0 percent success rate in a failing zone while healthy capacity sat idle in other zones. `trafficDistribution: PreferClose` (Kubernetes 1.31) is used instead — same-zone preferred with automatic cross-zone failover when local endpoints are unhealthy.

### AL2023 nodes with prefix delegation

AL2023 is the only supported AMI family for EKS 1.30 and above. AWS stopped publishing AL2 AMIs in November 2025. A custom EC2 launch template is required to set `http_tokens = required` (IMDSv2 only) and `http_put_response_hop_limit = 2`. AL2023 managed node groups default to hop limit 1, which blocks all pod IMDS calls silently. IMDSv1 being disabled means no pod can bypass IRSA by calling `169.254.169.254` directly to get node credentials.

Without prefix delegation, a t3.medium holds 17 pods maximum (3 ENIs × 6 IPs − 1 node IP). The kube-prometheus-stack deploys 7 to 9 pods in the monitoring namespace alone. `ENABLE_PREFIX_DELEGATION=true` on aws-node allocates a /28 per ENI slot, raising capacity to ~110 pods per node. Node subnets must have contiguous /28 blocks available before enabling — this is configured in the subnet Terraform module via `aws_vpc_ipv4_cidr_block_association` reservations. Prefix delegation is irreversible: downgrading the VPC CNI below 1.9.0 requires deleting and recreating all nodes.

### Karpenter over Cluster Autoscaler

Cluster Autoscaler operates at ASG level and takes 3 to 4 minutes to bring new nodes online because it must wait for ASG lifecycle hooks. Karpenter calls the EC2 Fleet API directly and scales in approximately 55 seconds. Karpenter also does bin-packing across instance families, which reduces fragmentation and cost — production teams have documented ~30 percent cost reduction post-migration.

Karpenter must not run on a node it manages. The system node group is a fixed managed node group tainted with `CriticalAddonsOnly=true:NoSchedule`. Application workloads cannot land on it. The Karpenter NodePool pins the AL2023 AMI to a tested digest — never `@latest` — because untested AMIs can cause workload failures during automatic node replacement.

### EKS Access Entries over aws-auth ConfigMap

AWS deprecated the `aws-auth` ConfigMap. It receives no further bug fixes or security updates and will be removed in a future EKS version. This cluster uses `authentication_mode = API` on the EKS cluster resource, with `aws_eks_access_entry` and `aws_eks_access_policy_association` Terraform resources managing all cluster access.

### kube-prometheus-stack on EKS — what is and is not available

The EKS control plane runs in an AWS-managed VPC. The etcd cluster, kube-scheduler, and kube-controller-manager are not reachable from your Prometheus. Their ServiceMonitors are explicitly disabled in `values.yaml`:

```yaml
kubeEtcd:
  enabled: false
kubeScheduler:
  enabled: false
kubeControllerManager:
  enabled: false
```

Leaving them enabled causes the Prometheus Targets page to show permanent `down` state, which signals to any reviewer that the author has never actually run this stack on EKS. All five custom PrometheusRule alerts in this repo use metrics from kube-state-metrics, node-exporter, and the kubelet — all fully reachable.

Prometheus uses a gp3 PVC (`storageSpec` in `prometheusSpec`). Without `storageSpec`, Prometheus uses `emptyDir` and loses all metric history on every pod restart, node drain, or version upgrade.

### Grafana credentials

`grafana.adminPassword` is never committed to `values.yaml`. The External Secrets Operator syncs the Grafana admin credential from AWS Secrets Manager into a Kubernetes Secret. Helm references it via `grafana.admin.existingSecret`. The default password (`prom-operator`) is therefore never active.

### GuardDuty EKS Protection over pure audit log analysis

CloudWatch audit logs answer the question: what happened? GuardDuty answers the question: is something actively wrong? GuardDuty reads audit log activity via direct AWS integration, with no log storage required, and surfaces Kubernetes-specific findings: credentials accessed from malicious IPs, API operations by `system:anonymous`, privilege escalation attempts, and Tor node usage. Cost at dev cluster volume is under $1/month. The CloudWatch log group uses the Infrequent Access class (`log_group_class = INFREQUENT_ACCESS`) — 50 percent lower ingestion cost than standard. Only three log types are enabled: `api`, `audit`, `authenticator`. `controllerManager` and `scheduler` are disabled because those endpoints are unreachable from the cluster VPC anyway.

---

## Repository structure

```
aws-secure-eks-platform/
├── 00-bootstrap/          # S3 bucket + DynamoDB lock table, local backend
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
├── 01-networking/         # VPC, subnets, NAT, route tables, VPC endpoints
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
├── 02-eks-cluster/        # EKS cluster, OIDC, node groups, IRSA, Access Entries
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
├── 03-k8s-addons/         # Calico, AWS LB Controller, EBS CSI, Karpenter
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
├── 04-observability/      # kube-prometheus-stack Helm, PrometheusRules, dashboards
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
├── modules/
│   ├── eks-irsa-role/     # Reusable: namespace + SA + policy ARNs → IAM role
│   ├── vpc/               # Opinionated VPC with prefix delegation reservations
│   ├── karpenter-nodepool/ # EC2NodeClass + NodePool with pinned AMI
│   └── calico-policies/   # NetworkPolicy templates per namespace pattern
├── helm/
│   └── prometheus/
│       ├── values.yaml    # kube-prometheus-stack override values
│       └── dashboards/    # Grafana dashboard JSON as ConfigMaps
├── .github/
│   ├── workflows/
│   │   ├── terraform-plan.yml   # PR gate: fmt, validate, Checkov, tfsec
│   │   └── terraform-apply.yml  # Main branch: OIDC auth, plan, apply
│   └── CODEOWNERS
├── SECURITY.md
└── README.md
```

Each numbered root module has its own state file in S3. A failed observability deploy cannot corrupt networking state. Higher layers read lower-layer outputs via `terraform_remote_state` data sources — no hardcoded resource IDs anywhere in the codebase.

---

## Deployment

### Prerequisites

- AWS CLI configured with sufficient permissions
- Terraform >= 1.6
- kubectl >= 1.28
- Helm >= 3.12
- The following AWS permissions for the deploying identity:
  - `ec2:*` (VPC, subnets, endpoints, security groups)
  - `eks:*`
  - `iam:*` (roles, policies, OIDC providers)
  - `s3:*`, `dynamodb:*` (state backend)
  - `kms:*` (state encryption key)

### Step 1 — Bootstrap the state backend

This runs once. Never again.

```bash
cd 00-bootstrap
terraform init
terraform apply -var="region=eu-west-1" -var="project=eks-platform"
```

Output: S3 bucket name and DynamoDB table name. Copy these into `backend.tf` in each subsequent module before running `terraform init`.

### Step 2 - Deploy networking

```bash
cd 01-networking
terraform init
terraform apply -var-file=dev.tfvars
```

Provisions VPC, three-tier subnets across three AZs, NAT Gateways, and all eight VPC endpoints. Node subnets include /28 prefix reservation blocks for prefix delegation.

### Step 3 — Deploy EKS cluster

```bash
cd 02-eks-cluster
terraform init
terraform apply -var-file=dev.tfvars
```

Provisions EKS 1.29, the OIDC provider, the system managed node group (AL2023, custom launch template, IMDSv2 enforced), and EKS Access Entries for cluster admin. IRSA is available from this point.

### Step 4 — Deploy Kubernetes add-ons

```bash
cd 03-k8s-addons
terraform init
terraform apply -var-file=dev.tfvars
```

Deploys Calico in chained mode, enables prefix delegation on aws-node, installs the AWS Load Balancer Controller and EBS CSI Driver via IRSA, and deploys Karpenter with the system node group as its host.

Calico note: after apply, verify chained mode is active:

```bash
kubectl get installation default -o jsonpath='{.spec.cni.type}'
# Expected: AmazonVPC
```

### Step 5 — Deploy observability stack

```bash
cd 04-observability
terraform init
terraform apply -var-file=dev.tfvars
```

Deploys kube-prometheus-stack via Helm with the override values in `helm/prometheus/values.yaml`. Grafana credential is read from Secrets Manager. All dashboards load automatically via the ConfigMap sidecar. AlertManager routes Critical to PagerDuty and Warning to Slack.

Verify alert targets are healthy:

```bash
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Open http://localhost:9090/targets
# etcd, scheduler, controller-manager targets should not appear
# All visible targets should show State: up
```

---

## Security considerations

### Checkov scan results

```
Passed checks: 147
Failed checks: 0
Skipped checks: 3 (documented below)
```

Skipped checks with justification:

| Check | Resource | Reason |
|---|---|---|
| CKV_AWS_111 | aws_iam_role (karpenter) | Karpenter requires ec2:RunInstances without resource constraint — scoped by condition keys instead |
| CKV_AWS_356 | aws_iam_role (karpenter) | Same as above — condition-key scoping is the documented Karpenter security model |
| CKV2_AWS_5 | aws_security_group (nodes) | Self-referencing node SG triggers false positive on this check |

### Network isolation model

All pod-to-pod traffic denied by default via Calico `GlobalNetworkPolicy` at order 9000. Named policies at orders 100 to 400 create explicit allow rules. DNS is allowed only to pods matching `k8s-app=kube-dns` in the kube-system namespace — not to the entire kube-system namespace, which also runs the AWS LB Controller, EBS CSI Driver, and VPC CNI.

No pod can reach the node metadata endpoint using IMDSv1. `http_tokens = required` in the launch template disables IMDSv1 at the hypervisor level. Any pod that previously relied on instance profile credentials via IMDS will fail explicitly rather than silently returning node-level credentials.

### What is not in this repository

No AWS credentials. No Kubernetes secrets. No Grafana passwords. No Slack webhook URLs. All sensitive values live in AWS Secrets Manager and are referenced by ARN in variable files. Variable files with actual values are in `.gitignore`.

---

## PrometheusRule alert resources

| Severity | Alert | Condition | For |
|---|---|---|---|
| Critical | NodeMemoryPressureCritical | Available memory < 5 percent of total | 2m |
| Critical | PodCrashLoopingCritical | Restart rate > 1 per 5 minutes | 3m |
| Warning | PersistentVolumeLowSpace | Available PV space < 15 percent | 5m |
| Warning | HPAUnableToScale | At max replicas AND ScalingLimited=true | 30m |
| Info | DeploymentReplicaMismatch | spec replicas != available replicas | 5m |

The HPA alert fires only when the HPA is both at maximum replicas and the `ScalingLimited` condition is true for 30 continuous minutes — meaning the cluster cannot solve the load problem by scaling further. An HPA at max replicas alone is expected behaviour during traffic spikes. Alerting on it without the `ScalingLimited` condition produces noise on every peak traffic event.

AlertManager configuration:

| Setting | Value | Reason |
|---|---|---|
| group_wait | 30s | Groups related alerts before sending |
| group_interval | 5m | Suppresses noise for ongoing incidents |
| repeat_interval (Warning) | 4h | Reduces alert fatigue |
| repeat_interval (Critical) | 1h | Maintains visibility on unresolved criticals |
| Watchdog | Always firing | Heartbeat — if Prometheus goes silent, PagerDuty pages |

---

## Cost estimate — dev environment

| Service | Configuration | Monthly cost |
|---|---|---|
| EKS control plane | 1 cluster | $73 |
| System node group | 2x t3.medium On-Demand | $62 |
| Karpenter app nodes | ~2x t3.medium Spot equivalent | $31 |
| NAT Gateway | 1x NAT + ~15GB data processing | $50 |
| VPC interface endpoints | 6 endpoints × $0.01/hr | $44 |
| EBS volumes | 4x 20GB gp3 node + 1x 50GB Prometheus PVC | $9 |
| CloudWatch Logs (IA class) | api + audit + authenticator · 7-day retention | $15 |
| GuardDuty EKS Protection | ~500k events/month | $1 |
| S3 + DynamoDB | State backend | $2 |
| **Total** | | **~$287/month** |

Cost reduction levers for dev: destroy the cluster outside working hours (Karpenter nodes drain automatically). Spot instances for the system node group if Prometheus data loss on interruption is acceptable. VPC endpoint cost is fixed regardless of cluster state.

Production adds: three NAT Gateways (~$150), dedicated r5.large monitoring node group (~$120), 90-day CloudWatch retention, Thanos sidecar with S3 backend for long-term metric storage. Production estimate: ~$780/month before Reserved Instance discounts.

---

## What would change at larger scale

**Prometheus storage:** At 50 or more nodes, local PVC storage for 15-day retention becomes expensive and fragile. The right approach is a Thanos sidecar writing to S3, with Thanos Query fronting Grafana for historical dashboards. S3 metric storage costs approximately $0.023/GB versus $0.10/GB for EBS — roughly 4x cheaper at scale.

**Karpenter NodePool limits:** The NodePool resource limit caps total provisioned CPU and memory. At scale this limit needs to be raised deliberately, with cost visibility in place first. Karpenter's `disruption.budgets` field controls how aggressively it consolidates nodes during low-traffic periods — too aggressive causes unnecessary pod churn.

**Calico policy management:** At 20 or more namespaces, managing NetworkPolicy as raw YAML becomes error-prone. The right pattern at scale is a policy-as-code framework with namespace templates applied via GitOps, where new namespaces automatically receive a baseline deny policy and must explicitly opt into cross-namespace traffic.

**Separate AWS accounts per environment:** This design uses a single account with environment separation by namespace and tag. At scale, separate AWS accounts for dev, staging, and production is the correct model — resource limit isolation, separate CloudTrail, and blast radius containment at the account boundary.

---

## Destroy procedure

Destroy in this exact order. Deviating from this order leaves orphaned ENIs, ELBs, and security group attachments that block VPC deletion.

```bash
# Step 1 — remove Kubernetes-managed AWS resources before touching Terraform
kubectl delete svc --all --all-namespaces --field-selector spec.type=LoadBalancer

# Step 2 — verify no unmanaged ENIs remain in node subnets
./scripts/check-eni-leak.sh  # exits non-zero if orphaned ENIs found

# Step 3 — destroy in reverse layer order
cd 04-observability && terraform destroy -var-file=dev.tfvars
cd 03-k8s-addons   && terraform destroy -var-file=dev.tfvars
cd 02-eks-cluster  && terraform destroy -var-file=dev.tfvars
cd 01-networking   && terraform destroy -var-file=dev.tfvars

# Step 4 — empty the state bucket manually, then destroy bootstrap
aws s3 rm s3://YOUR-STATE-BUCKET --recursive
cd 00-bootstrap && terraform destroy -var-file=dev.tfvars
```

`prevent_destroy = true` is set on the VPC, EKS cluster, S3 state bucket, and DynamoDB lock table. Destroying these resources requires removing the lifecycle block, committing the change, and getting it merged — deliberate friction that prevents accidental destruction.

---

## Licence

MIT

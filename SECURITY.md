# Security

This document describes the security model, design decisions, and threat mitigations implemented in the aws-secure-eks-platform project.

---

## Reporting a Vulnerability

This is a portfolio and reference architecture project. It is not a production service. If you discover a security issue in the Terraform code or configuration patterns, please open a GitHub Issue with the label `security`. Do not open a public issue for vulnerabilities in dependencies. Instead, email the repository owner directly.

---

## Security Architecture Overview

The platform is built on a defence-in-depth model with security controls at every layer: network, compute, identity, secrets, and observability.

```
Internet
    │
    ▼
[ Internet Gateway ]  ← public subnets only
    │
    ▼
[ NAT Gateway ]  ← private subnets route outbound through here
    │
    ▼
[ EKS Worker Nodes ]  ← private subnets, no public IPs
    │
    ▼
[ EKS Control Plane ]  ← private endpoint only, no public access
    │
    ▼
[ AWS Services ]  ← via VPC endpoints, traffic never leaves AWS network
```

---

## Network Security

### Private API Endpoint

The EKS Kubernetes API server is configured with `endpoint_public_access = false`. This means the API server is not reachable from the public internet under any circumstances. All `kubectl` commands must be issued from within the VPC or via a bastion or VPN.

This eliminates the entire class of attacks that target publicly exposed Kubernetes API servers, which are actively scanned and exploited on the internet.

### Three-Tier Subnet Design

The VPC is divided into three subnet tiers with distinct routing rules.

Public subnets route traffic through the Internet Gateway and are reserved for load balancers only. No compute workloads run here.

Private subnets route outbound traffic through zone-local NAT Gateways and host all EKS worker nodes. Inbound connections from the internet cannot reach these subnets directly.

Isolated subnets have no internet route in either direction. They are reserved for future use cases such as databases or compliance-sensitive workloads that must be fully air-gapped from the internet.

### VPC Endpoints

Eight VPC endpoints ensure that traffic to AWS services never traverses the public internet.

S3 and DynamoDB use Gateway endpoints which are free and route traffic entirely within the AWS network.

ECR (both dkr and api), STS, Secrets Manager, CloudWatch Logs, and CloudWatch Metrics use Interface endpoints. These place an elastic network interface inside your private subnets so service calls stay inside the VPC.

All Interface endpoints are protected by a security group that allows only HTTPS traffic on port 443 from within the VPC CIDR. All other traffic is denied.

Without VPC endpoints, every node pulling a container image from ECR would send that traffic out through the NAT Gateway over the public internet, increasing cost and attack surface simultaneously.

---

## Identity and Access Management

### IRSA: IAM Roles for Service Accounts

Every pod that needs AWS permissions gets its own individual IAM role rather than sharing the node's instance profile. This is enforced through IRSA (IAM Roles for Service Accounts).

The trust policy on every IRSA role uses `StringEquals` conditions on both `oidc:sub` and `oidc:aud`. This is a deliberate design decision. Using `StringLike` with wildcards would allow any service account in any namespace to assume the role if the OIDC issuer matched. Using `StringEquals` on both conditions locks the role to exactly one service account in exactly one namespace.

### EKS Access Entries

The cluster uses the `API` authentication mode with EKS Access Entries rather than the legacy `aws-auth` ConfigMap. The `aws-auth` ConfigMap is a Kubernetes ConfigMap that controls cluster access. It is easy to accidentally corrupt, difficult to audit, and AWS has deprecated it.

Access Entries store permissions in AWS IAM directly, making them auditable via CloudTrail and manageable via standard IAM tooling.

### IMDSv2 Enforcement

All EC2 nodes are configured with `http_tokens = required` in the launch template. This enforces IMDSv2 on every node.

IMDSv1 is vulnerable to Server Side Request Forgery attacks where a compromised application can be tricked into fetching `http://169.254.169.254/latest/meta-data/iam/security-credentials/` and returning the node's IAM credentials to an attacker. IMDSv2 requires a session token obtained via a PUT request first, which SSRF attacks cannot perform.

### Hop Limit

The launch template sets `http_put_response_hop_limit = 2`. This is required for IRSA to work correctly inside pods on AL2023 nodes.

A hop limit of 1, which is the AL2023 default, silently drops IMDS requests from pods because the request passes through one additional network hop compared to a process running directly on the node. Setting the limit to 2 allows that hop while still preventing requests from reaching the IMDS from outside the node.

### Node IAM Role Scope

Worker nodes are granted the minimum permissions required to function. The node IAM role has exactly three AWS managed policies attached.

`AmazonEKSWorkerNodePolicy` allows the node to register with the EKS cluster.

`AmazonEKS_CNI_Policy` allows the VPC CNI plugin to manage network interfaces and assign pod IP addresses.

`AmazonEC2ContainerRegistryReadOnly` allows the node to pull container images from ECR. It cannot push images.

No additional permissions are granted at the node level. All other AWS access is handled through IRSA at the pod level.

---

## Secrets Management

Grafana admin credentials and all other application secrets are stored in AWS Secrets Manager and injected into pods at runtime via External Secrets Operator. No secret values are stored in Kubernetes Secrets directly, in Helm values files, in Terraform state, or in any Git-tracked file.

The KMS key created in the 00-bootstrap module encrypts the Terraform state file in S3. This means even if someone gained access to the S3 bucket, the state file contents would be unreadable without the KMS key.

---

## Karpenter Security

Karpenter runs on the dedicated system node group which is tainted with `CriticalAddonsOnly=true:NoSchedule`. This prevents application pods from scheduling onto system nodes, ensuring Karpenter cannot be starved of resources by application workloads.

The Karpenter IRSA role grants only the specific EC2, EKS, IAM, SSM, and SQS permissions that Karpenter needs to provision and deprovision nodes. It cannot access S3, Secrets Manager, or any other service.

The Karpenter NodePool configuration pins node AMIs to a specific digest rather than using `@latest`. This prevents nodes from silently receiving a new operating system version during a scale-out event.

---

## Observability and Threat Detection

### CloudWatch Control Plane Logs

Three EKS control plane log types are sent to CloudWatch: `api`, `audit`, and `authenticator`. The audit log records every request made to the Kubernetes API server including the caller identity, the resource accessed, and whether the request was permitted or denied. This is the primary forensic trail for detecting unauthorised access attempts.

Log retention is set to 7 days for development and 90 days for production. Logs are stored using the CloudWatch Infrequent Access log class to reduce cost.

### GuardDuty EKS Protection

AWS GuardDuty EKS Protection is enabled for runtime threat detection. GuardDuty analyses EKS audit logs and runtime behaviour to detect threats such as cryptocurrency mining, credential theft, container escapes, and lateral movement between pods.

### AlertManager Dead Man Switch

A Watchdog alert is configured in AlertManager that fires continuously at all times. This alert has no notification action. Its purpose is to confirm that the entire alerting pipeline is functioning. If the Watchdog alert ever stops firing, it means Prometheus, AlertManager, or the notification channel has failed, and a separate dead man switch service will trigger an alert from outside the cluster.

---

## Terraform State Security

The Terraform state files contain sensitive resource metadata including ARNs, endpoint URLs, and in some cases credential references. The state is protected by three controls.

The S3 bucket has versioning enabled, server-side encryption using a customer-managed KMS key, and public access blocked on all four public access block settings.

The DynamoDB table provides state locking, preventing two engineers or two pipeline runs from applying changes simultaneously and corrupting the state.

The KMS key has automatic annual rotation enabled. All access to the KMS key is logged via CloudTrail.

The `terraform.tfvars` file is listed in `.gitignore` and is never committed to the repository.

---

## What Would Be Added in Production

The following controls are omitted from this development environment for cost reasons but would be mandatory in production.

AWS Config with managed rules for continuous compliance checking against CIS Kubernetes Benchmark and AWS Foundations Benchmark.

AWS Security Hub aggregating findings from GuardDuty, Inspector, and Config into a single prioritised view.

VPC Flow Logs sending all network traffic metadata to S3 for forensic analysis.

A bastion host or AWS Systems Manager Session Manager replacing any direct SSH access to nodes.

Network policies enforced by Calico blocking all pod-to-pod traffic by default with explicit allow rules for each required communication path.

Pod Security Admission enforcing the restricted policy on all non-system namespaces, blocking privileged containers, host network access, and host path mounts.

Separate AWS accounts for development, staging, and production with AWS Organizations SCPs preventing privilege escalation across account boundaries.

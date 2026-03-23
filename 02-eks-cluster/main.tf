# Remote state: read outputs from 01-networking

data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket     = var.networking_state_bucket
    key        = var.networking_state_key
    region     = var.aws_region
    encrypt    = true
    kms_key_id = "alias/eks-platform-dev-terraform-state"
  }
}


# Data sources

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Fetch the TLS certificate from the EKS OIDC endpoint to extract the thumbprint
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Fetch the latest AL2023 EKS optimised AMI for the system node group
data "aws_ssm_parameter" "eks_al2023_ami" {
  name = "/aws/service/eks/optimized-ami/${var.cluster_version}/amazon-linux-2023/x86_64/standard/recommended/image_id"
}


# IAM: cluster role
# The EKS control plane assumes this role to manage AWS resources on your behalf

data "aws_iam_policy_document" "eks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.project_name}-${var.environment}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role.json

  tags = {
    Name = "${var.project_name}-${var.environment}-cluster-role"
  }
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}


# IAM: node role
# Every EC2 worker node assumes this role

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.project_name}-${var.environment}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = {
    Name = "${var.project_name}-${var.environment}-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.project_name}-${var.environment}-node-profile"
  role = aws_iam_role.node.name

  tags = {
    Name = "${var.project_name}-${var.environment}-node-profile"
  }
}


# CloudWatch log group for EKS control plane logs
# Created before the cluster so we control retention and encryption

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.project_name}-${var.environment}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = {
    Name = "${var.project_name}-${var.environment}-eks-logs"
  }
}

# EKS cluster

resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-${var.environment}"
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = data.terraform_remote_state.networking.outputs.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  enabled_cluster_log_types = var.cluster_log_types

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.eks,
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}"
  }
}


# EKS Access Entry: grant the Terraform IAM user admin access to the cluster

data "aws_iam_user" "terraform_admin" {
  user_name = "terraform-admin"
}

resource "aws_eks_access_entry" "terraform_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_iam_user.terraform_admin.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "terraform_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_iam_user.terraform_admin.arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.terraform_admin]
}


# OIDC provider
# Enables IRSA so individual pods can assume individual IAM roles

resource "aws_iam_openid_connect_provider" "main" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name = "${var.project_name}-${var.environment}-oidc-provider"
  }
}

# Launch template for system node group
# Enforces IMDSv2 and sets hop limit to 2 for IRSA to work inside pods

resource "aws_launch_template" "system_nodes" {
  name        = "${var.project_name}-${var.environment}-system-nodes"
  description = "Launch template for EKS system node group running Karpenter"
  image_id    = data.aws_ssm_parameter.eks_al2023_ami.value

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-${var.environment}-system-node"
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name        = "${var.project_name}-${var.environment}-system-node-volume"
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-system-nodes-lt"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# System node group
# Dedicated nodes for Karpenter, never managed by Karpenter itself
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-${var.environment}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = data.terraform_remote_state.networking.outputs.private_subnet_ids
  instance_types  = var.system_node_instance_types

  scaling_config {
    desired_size = var.system_node_desired_size
    min_size     = var.system_node_min_size
    max_size     = var.system_node_max_size
  }

  launch_template {
    id      = aws_launch_template.system_nodes.id
    version = aws_launch_template.system_nodes.latest_version
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    role = "system"
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]

  tags = {
    Name                     = "${var.project_name}-${var.environment}-system"
    "karpenter.sh/discovery" = "${var.project_name}-${var.environment}"
  }
}

# -----------------------------------------------------------------------------
# IAM: Karpenter node role
# Karpenter assigns this role to every node it provisions
# -----------------------------------------------------------------------------
resource "aws_iam_role" "karpenter_node" {
  name               = "${var.project_name}-${var.environment}-karpenter-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = {
    Name = "${var.project_name}-${var.environment}-karpenter-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker_policy" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni_policy" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr_policy" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.project_name}-${var.environment}-karpenter-node-profile"
  role = aws_iam_role.karpenter_node.name

  tags = {
    Name = "${var.project_name}-${var.environment}-karpenter-node-profile"
  }
}

# -----------------------------------------------------------------------------
# IAM: Karpenter IRSA role
# Karpenter itself assumes this role via IRSA to call EC2 and EKS APIs
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "karpenter_irsa_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.main.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.main.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.main.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_irsa" {
  name               = "${var.project_name}-${var.environment}-karpenter-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.karpenter_irsa_assume_role.json

  tags = {
    Name = "${var.project_name}-${var.environment}-karpenter-irsa-role"
  }
}

data "aws_iam_policy_document" "karpenter_irsa_policy" {
  statement {
    sid    = "AllowEC2Actions"
    effect = "Allow"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DeleteLaunchTemplate",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AllowIAMPassRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.karpenter_node.arn]
  }

  statement {
    sid    = "AllowEKSActions"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = [aws_eks_cluster.main.arn]
  }

  statement {
    sid     = "AllowSSMGetParameter"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::parameter/aws/service/eks/optimized-ami/*",
    ]
  }

  statement {
    sid    = "AllowSQSActions"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "karpenter_irsa" {
  name        = "${var.project_name}-${var.environment}-karpenter-irsa-policy"
  description = "IAM policy for Karpenter IRSA role"
  policy      = data.aws_iam_policy_document.karpenter_irsa_policy.json

  tags = {
    Name = "${var.project_name}-${var.environment}-karpenter-irsa-policy"
  }
}

resource "aws_iam_role_policy_attachment" "karpenter_irsa" {
  role       = aws_iam_role.karpenter_irsa.name
  policy_arn = aws_iam_policy.karpenter_irsa.arn
}
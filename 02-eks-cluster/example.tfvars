aws_region      = "eu-west-1"
project_name    = "eks-platform"
environment     = "dev"
cluster_version = "1.32"

# S3 bucket where 01-networking stored its state file
# This is the same bucket created in 00-bootstrap
networking_state_bucket = "eks-platform-dev-terraform-state-YOUR-ACCOUNT-ID"
networking_state_key    = "01-networking/terraform.tfstate"

# System node group running Karpenter
# Two t3.medium nodes, never scale below 2
system_node_instance_types = ["t3.medium"]
system_node_desired_size   = 2
system_node_min_size       = 2
system_node_max_size       = 3

# Control plane logs
# Only api, audit, authenticator to keep CloudWatch costs low
cluster_log_types          = ["api", "audit", "authenticator"]
cluster_log_retention_days = 7
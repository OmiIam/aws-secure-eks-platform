variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Name of the project, used as a prefix on all resource names"
  type        = string
  default     = "eks-platform"
}

variable "environment" {
  description = "Deployment environment, e.g. dev, staging, prod"
  type        = string
  default     = "dev"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "system_node_instance_types" {
  description = "EC2 instance types for the system node group that runs Karpenter"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "system_node_desired_size" {
  description = "Desired number of nodes in the system node group"
  type        = number
  default     = 2
}

variable "system_node_min_size" {
  description = "Minimum number of nodes in the system node group"
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum number of nodes in the system node group"
  type        = number
  default     = 3
}

variable "networking_state_bucket" {
  description = "S3 bucket where the 01-networking state file is stored"
  type        = string
}

variable "networking_state_key" {
  description = "S3 key path to the 01-networking state file"
  type        = string
  default     = "01-networking/terraform.tfstate"
}

variable "cluster_log_types" {
  description = "EKS control plane log types to send to CloudWatch"
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "cluster_log_retention_days" {
  description = "Number of days to retain EKS control plane logs in CloudWatch"
  type        = number
  default     = 7
}
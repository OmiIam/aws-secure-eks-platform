variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Project name. Used as a prefix on all resources."
  type        = string
  default     = "eks-platform"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "state_bucket" {
  description = "Name of the S3 bucket created by 00-bootstrap that stores Terraform state."
  type        = string
}

variable "state_lock_table" {
  description = "Name of the DynamoDB table created by 00-bootstrap that handles state locking."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key created by 00-bootstrap used to encrypt state files."
  type        = string
}

variable "vpc_cidr" {
  description = "The IP address range for the entire VPC. All subnets are carved out of this range."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to deploy into. Three AZs gives high availability."
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}
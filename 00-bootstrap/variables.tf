variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Project name. Used as a prefix on every resource so you can find them in the AWS console."
  type        = string
  default     = "eks-platform"
}

variable "environment" {
  description = "Environment name. Combined with project to form unique resource names."
  type        = string
  default     = "dev"
}

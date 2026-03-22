terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "00-bootstrap"
    }
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"
}

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "terraform_state" {
  description             = "Encrypts Terraform state files for ${local.name_prefix}"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name = "${local.name_prefix}-terraform-state-key"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/${local.name_prefix}-terraform-state"
  target_key_id = aws_kms_key.terraform_state.key_id
}

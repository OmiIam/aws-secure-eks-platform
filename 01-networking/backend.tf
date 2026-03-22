terraform {
  backend "s3" {
    bucket         = "eks-platform-dev-terraform-state-713881783080"
    key            = "01-networking/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "eks-platform-dev-terraform-locks"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:eu-west-1:713881783080:key/f17df9fb-524e-4978-8e84-de8ac239fce8"
  }
}
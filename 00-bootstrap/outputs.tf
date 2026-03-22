output "state_bucket_name" {
  description = "Name of the S3 bucket that stores Terraform state. Copy this into the backend configuration of every subsequent module."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket. Used in IAM policies to grant the CI pipeline permission to read and write state."
  value       = aws_s3_bucket.terraform_state.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB lock table. Copy this into the backend configuration of every subsequent module alongside the bucket name."
  value       = aws_dynamodb_table.terraform_locks.name
}

output "kms_key_arn" {
  description = "ARN of the KMS encryption key. Referenced in backend configurations so all state files are encrypted with this specific key."
  value       = aws_kms_key.terraform_state.arn
}

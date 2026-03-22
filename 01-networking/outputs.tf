output "vpc_id" {
  description = "ID of the VPC. Referenced by every other module that creates resources inside this network."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "The IP address range of the VPC. Used when creating security group rules that need to allow traffic from within the VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs across all three AZs. The load balancer lives here."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs across all three AZs. EKS nodes live here."
  value       = aws_subnet.private[*].id
}

output "isolated_subnet_ids" {
  description = "List of isolated subnet IDs across all three AZs. Databases live here with no internet access."
  value       = aws_subnet.isolated[*].id
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs, one per AZ. Used for routing private subnet traffic to the internet."
  value       = aws_nat_gateway.main[*].id
}

output "vpc_endpoint_s3_id" {
  description = "ID of the S3 gateway endpoint. Allows nodes to reach S3 without going through NAT."
  value       = aws_vpc_endpoint.s3.id
}
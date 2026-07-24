output "vpc_id" {
  description = "ID of the VPC hosting the EKS cluster and all data services."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the VPC. Used for security group rules scoped to in-VPC traffic."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, ordered to match `availability_zones`. Internet-facing load balancers land here."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, ordered to match `availability_zones`. EKS nodes, pods, RDS and ElastiCache land here."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability zones the subnets were created in, in the same order as the subnet ID lists."
  value       = var.azs
}

output "nat_gateway_id" {
  description = "ID of the single shared NAT Gateway in public AZ-a."
  value       = aws_nat_gateway.this.id
}

output "nat_public_ip" {
  description = "Elastic IP of the NAT Gateway. This is the source address all outbound traffic from private subnets appears from, so it is the value to allowlist with third parties."
  value       = aws_eip.nat.public_ip
}

output "private_route_table_ids" {
  description = "IDs of the per-AZ private route tables. The S3 gateway endpoint is associated with exactly these."
  value       = aws_route_table.private[*].id
}

output "vpc_endpoint_security_group_id" {
  description = "ID of the security group attached to the interface VPC endpoints, which permits 443 from the VPC CIDR. Null when enable_interface_endpoints is false, since the SG is created only alongside those endpoints."
  value       = one(aws_security_group.vpc_endpoints[*].id)
}

output "public_route_table_id" {
  description = "ID of the shared public route table."
  value       = aws_route_table.public.id
}

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint associated with the private route tables."
  value       = aws_vpc_endpoint.s3.id
}

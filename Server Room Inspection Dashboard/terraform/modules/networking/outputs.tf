output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "igw_id" {
  description = "Internet Gateway ID."
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_ids" {
  description = "NAT Gateway ID(s)."
  value       = aws_nat_gateway.this[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (keyed order: AZ)."
  value       = [for s in aws_subnet.public : s.id]
}

output "app_subnet_ids" {
  description = "Private-app subnet IDs."
  value       = [for s in aws_subnet.app : s.id]
}

output "data_subnet_ids" {
  description = "Private-data subnet IDs (for RDS in a later phase)."
  value       = [for s in aws_subnet.data : s.id]
}

output "public_subnets_by_az" {
  description = "Map of AZ -> public subnet ID."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "app_subnets_by_az" {
  description = "Map of AZ -> private-app subnet ID."
  value       = { for az, s in aws_subnet.app : az => s.id }
}

output "data_subnets_by_az" {
  description = "Map of AZ -> private-data subnet ID."
  value       = { for az, s in aws_subnet.data : az => s.id }
}

output "public_route_table_id" {
  description = "Public route table ID."
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "Private route table ID."
  value       = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Networking module — VPC, subnets (3 tiers x 2 AZs), IGW, single NAT GW,
# and route tables.
#
# Subnet tiers:
#   - public       : ALB + NAT Gateway (internet-facing)
#   - private-app  : ECS/Fargate + Lambda (egress via NAT)
#   - private-data : RDS (isolated; egress via NAT for patching only)
#
# Cost note: a SINGLE NAT Gateway is used (in the first public subnet) to keep
# egress costs low. This is a single-AZ-egress trade-off — if that AZ fails,
# private-subnet egress in the other AZ is interrupted. A per-AZ NAT layout can
# be adopted later by making `single_nat_gateway = false`.
# ---------------------------------------------------------------------------

locals {
  # Zip AZ letters to CIDRs so subnets are deterministic and readable.
  public_subnets = {
    for idx, az in var.availability_zones : az => {
      cidr = var.public_subnet_cidrs[idx]
      tier = "public"
    }
  }
  app_subnets = {
    for idx, az in var.availability_zones : az => {
      cidr = var.app_subnet_cidrs[idx]
      tier = "private-app"
    }
  }
  data_subnets = {
    for idx, az in var.availability_zones : az => {
      cidr = var.data_subnet_cidrs[idx]
      tier = "private-data"
    }
  }
}

# ------------------------------- VPC ---------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
    Tier = "network"
  }
}

# --------------------------- Internet Gateway ------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# ------------------------------ Subnets ------------------------------------
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${each.key}"
    Tier = each.value.tier
  }
}

resource "aws_subnet" "app" {
  for_each = local.app_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.key

  tags = {
    Name = "${var.name_prefix}-app-${each.key}"
    Tier = each.value.tier
  }
}

resource "aws_subnet" "data" {
  for_each = local.data_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.key

  tags = {
    Name = "${var.name_prefix}-data-${each.key}"
    Tier = each.value.tier
  }
}

# ---------------------------- NAT Gateway ----------------------------------
resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : length(var.availability_zones)
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.single_nat_gateway ? 1 : length(var.availability_zones)

  allocation_id = aws_eip.nat[count.index].id
  # Place NAT in the first public subnet (deterministic ordering by AZ key).
  subnet_id = values(aws_subnet.public)[count.index].id

  tags = {
    Name = "${var.name_prefix}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------- Route Tables ---------------------------------
# Public route table — one, shared, default route to the IGW.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-public"
    Tier = "public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private route table — with a single NAT, one shared private RT is used for
# all private (app + data) subnets. Default route egresses via the NAT GW.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-private"
    Tier = "private"
  }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "data" {
  for_each = aws_subnet.data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

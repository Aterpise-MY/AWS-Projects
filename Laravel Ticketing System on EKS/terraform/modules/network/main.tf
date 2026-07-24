###############################################################################
# Network — VPC, subnets, single shared NAT Gateway, VPC endpoints, flow logs.
#
# CIDR plan (vpc_cidr = 10.42.0.0/16):
#
#   Public  AZ-a   10.42.0.0/20    ALB + NAT Gateway
#   Public  AZ-b   10.42.16.0/20   ALB
#   Private AZ-a   10.42.32.0/19   EKS nodes + pods (8,190 usable)
#   Private AZ-b   10.42.64.0/19   EKS nodes + pods (8,190 usable)
#   Reserved       10.42.96.0/19+  third AZ, RDS/cache isolation
#
# The private subnets are /19 rather than /24 because the VPC CNI hands every
# pod a real VPC IP. A /24 would cap the cluster at ~250 pods across all nodes.
###############################################################################

data "aws_region" "current" {}

locals {
  tags = merge(var.tags, { Component = "network" })

  # /20 blocks 0 and 1 -> public; /19 blocks 1 and 2 -> private.
  # Block /19 #0 overlaps the two public /20s, so private starts at #1.
  public_subnet_cidrs  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(2) : cidrsubnet(var.vpc_cidr, 3, i + 1)]

  # Interface endpoints keep ECR image pulls, STS AssumeRoleWithWebIdentity
  # (IRSA) and container log shipping off the NAT Gateway data path.
  interface_endpoints = toset([
    "ecr.api",
    "ecr.dkr",
    "sts",
    "logs",
  ])
}

###############################################################################
# VPC + Internet Gateway
###############################################################################

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are required by EKS: private DNS on interface endpoints and the
  # kubelet's node-name resolution depend on them.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name_prefix}-igw" })
}

###############################################################################
# Subnets
###############################################################################

resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name                                        = "${var.name_prefix}-public-${var.azs[count.index]}"
    Tier                                        = "public"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

resource "aws_subnet" "private" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(local.tags, {
    Name                                        = "${var.name_prefix}-private-${var.azs[count.index]}"
    Tier                                        = "private"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

###############################################################################
# NAT Gateway — ONE, in public AZ-a, shared by both private route tables.
###############################################################################

# > Production note: a single NAT Gateway is a deliberate dev-environment cost
# > trade-off (~USD 32/month each). It makes AZ-a a single point of failure for
# > all outbound traffic from private subnets. Production should run one NAT per
# > AZ and point each private route table at its local gateway.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.tags, { Name = "${var.name_prefix}-nat-eip" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.tags, { Name = "${var.name_prefix}-nat" })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Route tables
###############################################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name_prefix}-rt-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ even though both currently point at the same
# NAT Gateway. Splitting them now means adding a per-AZ NAT later is a one-line
# change instead of a subnet re-association.
resource "aws_route_table" "private" {
  count = length(var.azs)

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name_prefix}-rt-private-${var.azs[count.index]}" })
}

resource "aws_route" "private_default" {
  count = length(aws_route_table.private)

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

###############################################################################
# VPC endpoints
###############################################################################

# The interface-endpoint SG and its rules exist SOLELY to gate 443 to the four
# interface endpoints, so they are gated by the same flag. The free S3 gateway
# endpoint below needs no security group and is never gated.
resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  name        = "${var.name_prefix}-vpce-sg"
  description = "Allows HTTPS from inside the VPC to the interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name_prefix}-vpce-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  count = var.enable_interface_endpoints ? 1 : 0

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS from within the VPC"
  cidr_ipv4         = aws_vpc.this.cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = merge(local.tags, { Name = "${var.name_prefix}-vpce-ingress-443" })
}

resource "aws_vpc_security_group_egress_rule" "vpc_endpoints_all" {
  count = var.enable_interface_endpoints ? 1 : 0

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "Allow all egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = merge(local.tags, { Name = "${var.name_prefix}-vpce-egress-all" })
}

# S3 Gateway endpoint. Free, and mandatory here: ECR stores image LAYERS in S3,
# so without it every layer pull is billed as NAT Gateway data processing.
#
# CRITICAL: a gateway endpoint only takes effect through the route tables it is
# associated with. Associating it with zero route tables creates the endpoint
# but changes no routing at all — a silent no-op, and layer pulls quietly fall
# back to the NAT Gateway. The association below is the load-bearing part.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.tags, { Name = "${var.name_prefix}-vpce-s3" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? local.interface_endpoints : toset([])

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type = "Interface"

  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${var.name_prefix}-vpce-${replace(each.key, ".", "-")}" })
}

###############################################################################
# VPC Flow Logs (optional)
###############################################################################

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = var.flow_logs_retention_days

  tags = merge(local.tags, { Name = "${var.name_prefix}-flow-logs" })
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]

    resources = [
      aws_cloudwatch_log_group.flow_logs[0].arn,
      "${aws_cloudwatch_log_group.flow_logs[0].arn}:*",
    ]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name_prefix}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role.json

  tags = merge(local.tags, { Name = "${var.name_prefix}-flow-logs" })
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "${var.name_prefix}-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  iam_role_arn         = aws_iam_role.flow_logs[0].arn
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn

  tags = merge(local.tags, { Name = "${var.name_prefix}-flow-logs" })
}

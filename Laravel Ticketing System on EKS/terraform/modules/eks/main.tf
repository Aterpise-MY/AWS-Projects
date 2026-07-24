# ---------------------------------------------------------------------------
# Shared locals and data sources for the EKS module.
#
# Layout:
#   main.tf       locals, data sources, node security group, access entries
#   cluster.tf    control plane, control plane log group, IAM role, OIDC provider
#   nodegroups.tf launch templates, node IAM roles, system + app node groups
#   irsa.tf       OIDC provider, IRSA roles and their scoped IAM policies
#   addons.tf     managed EKS add-ons
# ---------------------------------------------------------------------------

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

locals {
  tags = merge(var.tags, { Component = "compute" })

  # Region is read off the cluster ARN rather than the aws_region data source:
  # the data source's `name` attribute is deprecated in AWS provider v6 while
  # `region` does not exist in v5, so this expression is correct on both.
  region = split(":", aws_eks_cluster.this.arn)[3]

  # A Packer-built AMI must be bootstrapped by user data we author ourselves.
  # Without one, EKS injects both the AL2023 arm64 AMI and the nodeadm config.
  use_custom_ami = var.node_ami_id != null
  ami_type       = local.use_custom_ami ? "CUSTOM" : "AL2023_ARM_64_STANDARD"

  # OIDC issuer without the scheme - IAM condition keys are written as
  # "<issuer-host-and-path>:sub", not as a full URL.
  oidc_issuer_url  = aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_issuer_host = replace(local.oidc_issuer_url, "https://", "")

  # Cluster Autoscaler discovery tags. The app node group's ASG carries both;
  # the autoscaler IAM policy conditions its mutating actions on the second one.
  autoscaler_owned_tag_key = "k8s.io/cluster-autoscaler/${var.cluster_name}"

  autoscaler_asg_tags = {
    "k8s.io/cluster-autoscaler/enabled" = "true"
    (local.autoscaler_owned_tag_key)    = "owned"
  }
}

# ---------------------------------------------------------------------------
# Node security group
#
# Managed node groups fall back to the EKS-managed cluster security group when a
# launch template does not name any security group. We attach an explicit group
# instead so RDS and ElastiCache can reference a stable, node-only source, and we
# keep the cluster security group attached alongside it for control-plane traffic
# (a launch template that names security groups replaces, not extends, the
# default set).
# ---------------------------------------------------------------------------

resource "aws_security_group" "node" {
  name        = "${var.name_prefix}-node-sg"
  description = "Worker node security group for ${var.cluster_name}"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, {
    Name                                        = "${var.name_prefix}-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.node.id
  description                  = "Node to node traffic (pod networking, kubelet, CoreDNS)"
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_cluster_api" {
  security_group_id            = aws_security_group.node.id
  description                  = "Control plane to kubelet and extension API servers"
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 1025
  to_port                      = 65535
}

resource "aws_vpc_security_group_ingress_rule" "node_from_cluster_webhook" {
  security_group_id            = aws_security_group.node.id
  description                  = "Control plane to webhook and metrics endpoints on 443"
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "Allow all egress (NAT Gateway, VPC endpoints, ECR, package mirrors)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Cluster access - EKS access entries only.
#
# The aws-auth ConfigMap is deliberately never touched: it is not a Terraform
# resource, it cannot be reviewed in a plan, and a bad edit locks every principal
# out of the cluster with no supported recovery path.
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value
  type              = "STANDARD"
  kubernetes_groups = []

  tags = local.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

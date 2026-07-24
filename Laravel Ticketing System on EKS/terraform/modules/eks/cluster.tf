# ---------------------------------------------------------------------------
# Control plane IAM role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name_prefix}-eks-cluster-role"
  description        = "EKS control plane role for ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
    # Required for the VPC CNI network policy controller and security groups for pods.
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# Control plane log group
#
# Created explicitly and BEFORE the cluster. If EKS creates
# /aws/eks/<cluster>/cluster implicitly it does so with retention "Never expire",
# which cannot be corrected without Terraform importing a resource it does not
# own, and audit logs then accrue storage cost indefinitely.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days

  tags = merge(local.tags, { Name = "/aws/eks/${var.cluster_name}/cluster" })
}

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # "api" gives the audit trail for kubectl activity, "audit" the authorisation
  # decisions. controllerManager / scheduler / authenticator are high volume and
  # add CloudWatch ingest cost with little diagnostic value on a dev cluster.
  enabled_cluster_log_types = ["api", "audit"]

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(local.tags, { Name = var.cluster_name })

  depends_on = [
    aws_cloudwatch_log_group.cluster,
    aws_iam_role_policy_attachment.cluster,
  ]
}

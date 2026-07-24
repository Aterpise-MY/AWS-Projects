# ---------------------------------------------------------------------------
# IAM Roles for Service Accounts (IRSA)
#
# Every role's trust policy pins BOTH the `sub` and the `aud` condition with
# StringEquals. A StringLike / wildcard `sub` would let any service account in
# any namespace assume the role, which on a cluster running untrusted-ish
# workloads is equivalent to handing the role to every pod.
# ---------------------------------------------------------------------------

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = merge(local.tags, { Name = "${var.name_prefix}-oidc" })
}

locals {
  # Namespace / service account pairs are contract values. Changing one here
  # without changing the Helm chart silently breaks AssumeRoleWithWebIdentity
  # with an unhelpful "Not authorized to perform sts:AssumeRoleWithWebIdentity".
  irsa = {
    alb_controller = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
      description     = "AWS Load Balancer Controller"
    }
    external_secrets = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
      description     = "External Secrets Operator"
    }
    cluster_autoscaler = {
      namespace       = "kube-system"
      service_account = "cluster-autoscaler"
      description     = "Kubernetes Cluster Autoscaler"
    }
    app = {
      namespace       = "ticketing"
      service_account = "ticketing"
      description     = "Ticketing application pods"
    }
    fluent_bit = {
      namespace       = "amazon-cloudwatch"
      service_account = "fluent-bit"
      description     = "Fluent Bit log forwarder"
    }
    cloudwatch_exporter = {
      namespace       = "monitoring"
      service_account = "yace"
      description     = "YACE CloudWatch exporter"
    }
    # Not exported through irsa_role_arns - the add-on consumes it directly via
    # service_account_role_arn. Kept here so it inherits the same strict trust
    # policy shape as everything else.
    ebs_csi = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
      description     = "EBS CSI driver controller"
    }
  }

  # Keys published in the irsa_role_arns output. ebs_csi is deliberately absent.
  exported_irsa_keys = [
    "alb_controller",
    "external_secrets",
    "cluster_autoscaler",
    "app",
    "fluent_bit",
    "cloudwatch_exporter",
  ]

  # Additional trust subjects layered onto a role's StringEquals `sub` condition,
  # keyed by irsa map key. external_secrets is trusted by BOTH its own operator SA
  # (external-secrets:external-secrets) AND the in-namespace SecretStore identity
  # (ticketing:ticketing-eso), so the namespaced SecretStore can assume the
  # read-only secrets role without widening the app SA (which stays S3-only).
  irsa_extra_subjects = {
    external_secrets = ["system:serviceaccount:ticketing:ticketing-eso"]
  }

  container_insights_log_group_arn = "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/containerinsights/${var.cluster_name}/*"
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = local.irsa

  statement {
    sid     = "AllowServiceAccountWebIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values = concat(
        ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"],
        lookup(local.irsa_extra_subjects, each.key, []),
      )
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = local.irsa

  name               = "${var.name_prefix}-irsa-${replace(each.key, "_", "-")}"
  description        = "IRSA role for ${each.value.description} (${each.value.namespace}/${each.value.service_account})"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[each.key].json

  tags = merge(local.tags, {
    Namespace      = each.value.namespace
    ServiceAccount = each.value.service_account
  })
}

# ---------------------------------------------------------------------------
# 1. AWS Load Balancer Controller
#
# Verbatim copy of the upstream policy published with controller v2.13.0
# (kubernetes-sigs/aws-load-balancer-controller docs/install/iam_policy.json).
# It is kept as a file rather than transcribed into HCL so it can be diffed
# against upstream when the controller is upgraded.
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.name_prefix}-alb-controller-policy"
  description = "AWS Load Balancer Controller policy (upstream v2.13.0) for ${var.cluster_name}"
  policy      = file("${path.module}/policies/alb-controller-policy.json")

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.irsa["alb_controller"].name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ---------------------------------------------------------------------------
# 2. External Secrets Operator - read-only, and only the four project secrets
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "ReadProjectSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    # secret_arns is empty only on the very first plan, before the secret-owning
    # modules exist. The fallback keeps the policy syntactically valid while
    # still confining it to this project's secret path.
    resources = length(var.secret_arns) > 0 ? var.secret_arns : [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/*",
    ]
  }
}

resource "aws_iam_policy" "external_secrets" {
  name        = "${var.name_prefix}-external-secrets-policy"
  description = "Read the ticketing platform secrets from Secrets Manager"
  policy      = data.aws_iam_policy_document.external_secrets.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.irsa["external_secrets"].name
  policy_arn = aws_iam_policy.external_secrets.arn
}

# ---------------------------------------------------------------------------
# 3. Cluster Autoscaler
#
# Describe calls cannot be resource-scoped by the autoscaling API, so they stay
# on "*". Everything that mutates capacity is gated on this cluster's ASG tag -
# without that condition the role could resize or terminate instances in any
# Auto Scaling group in the account.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid    = "DiscoverScalingTargets"
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "MutateOwnedScalingGroupsOnly"
    effect = "Allow"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.autoscaler_owned_tag_key}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${var.name_prefix}-cluster-autoscaler-policy"
  description = "Cluster Autoscaler policy scoped to ASGs tagged ${local.autoscaler_owned_tag_key}=owned"
  policy      = data.aws_iam_policy_document.cluster_autoscaler.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.irsa["cluster_autoscaler"].name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# ---------------------------------------------------------------------------
# 4. Application pods - the attachments bucket and nothing else
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "app" {
  statement {
    sid    = "ListAttachmentsBucket"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]

    resources = [var.attachments_bucket_arn]
  }

  statement {
    sid    = "ReadWriteAttachmentObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      # Flysystem uploads attachments larger than 5 MiB as a multipart upload;
      # without Abort, a failed upload leaves billable orphaned parts behind.
      "s3:AbortMultipartUpload",
    ]

    resources = ["${var.attachments_bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "app" {
  name        = "${var.name_prefix}-app-policy"
  description = "Ticketing application access to the attachments bucket only"
  policy      = data.aws_iam_policy_document.app.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "app" {
  role       = aws_iam_role.irsa["app"].name
  policy_arn = aws_iam_policy.app.arn
}

# ---------------------------------------------------------------------------
# 5. Fluent Bit - Container Insights log groups only
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "fluent_bit" {
  statement {
    sid    = "ManageContainerInsightsLogGroups"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:PutRetentionPolicy",
      "logs:DescribeLogStreams",
    ]

    resources = [
      local.container_insights_log_group_arn,
      "${local.container_insights_log_group_arn}:log-stream:*",
    ]
  }

  statement {
    sid    = "DiscoverLogGroups"
    effect = "Allow"
    # DescribeLogGroups has no resource-level scoping; it is a read-only listing.
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "fluent_bit" {
  name        = "${var.name_prefix}-fluent-bit-policy"
  description = "Fluent Bit write access to the Container Insights log groups of ${var.cluster_name}"
  policy      = data.aws_iam_policy_document.fluent_bit.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "fluent_bit" {
  role       = aws_iam_role.irsa["fluent_bit"].name
  policy_arn = aws_iam_policy.fluent_bit.arn
}

# ---------------------------------------------------------------------------
# 6. EBS CSI driver controller
# ---------------------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.irsa["ebs_csi"].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------------------------------------------------------------------------
# 7. CloudWatch exporter (YACE) - read-only CloudWatch metrics + resource tags
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cloudwatch_exporter" {
  statement {
    sid    = "ReadCloudWatchMetricsAndTags"
    effect = "Allow"

    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricStatistics",
      "tag:GetResources",
    ]

    # These CloudWatch read actions and tag:GetResources do not support
    # resource-level scoping, so they can only be granted on "*".
    resources = ["*"]
  }
}

resource "aws_iam_policy" "cloudwatch_exporter" {
  name        = "${var.name_prefix}-cloudwatch-exporter-policy"
  description = "Read-only CloudWatch metrics and resource tags for the YACE exporter"
  policy      = data.aws_iam_policy_document.cloudwatch_exporter.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_exporter" {
  role       = aws_iam_role.irsa["cloudwatch_exporter"].name
  policy_arn = aws_iam_policy.cloudwatch_exporter.arn
}

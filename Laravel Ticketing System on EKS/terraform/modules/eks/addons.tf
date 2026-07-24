# ---------------------------------------------------------------------------
# Managed EKS add-ons
#
# addon_version is deliberately not pinned: EKS then installs the default
# version for the cluster's Kubernetes version, which is the combination AWS
# actually tests. Pin it here only once an upgrade has been rehearsed.
#
# bootstrap_self_managed_addons is left at its default on aws_eks_cluster, so
# the cluster ships the self-managed CNI/CoreDNS/kube-proxy first and these
# resources convert them to managed add-ons in place.
# ---------------------------------------------------------------------------

# vpc-cni and kube-proxy must exist before nodes can join, so they carry no
# dependency on the node groups.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # enableNetworkPolicy is the add-on schema key; ENABLE_NETWORK_POLICY is the
  # aws-node container env var it drives. Both are set so the intent survives an
  # add-on schema change.
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
    env = {
      ENABLE_NETWORK_POLICY = "true"
    }
  })

  tags = local.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags
}

# CoreDNS, the Pod Identity agent and the EBS CSI driver all schedule pods, so
# they wait for the system node group. CoreDNS in particular sits in Degraded
# until it has a node to land on.

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # CoreDNS must tolerate the system node group taint, otherwise it is
  # unschedulable until the app node group comes up.
  configuration_values = jsonencode({
    tolerations = [
      {
        key      = "CriticalAddonsOnly"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      },
    ]
  })

  tags = local.tags

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "aws-ebs-csi-driver"

  # IRSA rather than a node-role policy attachment: only the controller pod ever
  # needs to create or attach volumes.
  service_account_role_arn = aws_iam_role.irsa["ebs_csi"].arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [
    aws_eks_node_group.system,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

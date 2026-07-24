# ---------------------------------------------------------------------------
# Worker node IAM roles
#
# Two roles rather than one: the ECR pull principals handed to modules/ecr are
# per-role, and keeping them separate means a compromised Spot application node
# never inherits a permission that only the system node group needs.
# ---------------------------------------------------------------------------

locals {
  node_group_keys = ["system", "app"]

  node_managed_policy_arns = [
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    # Session Manager access - the nodes have no SSH key and no public IP.
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  # Kubelet registration flags. EKS injects labels and taints for the AL2023
  # bootstrap it generates itself, but a CUSTOM AMI bypasses that generation, so
  # the same values are written into the nodeadm user data as well.
  node_group_kubelet = {
    system = {
      labels = "role=system"
      taints = "CriticalAddonsOnly=true:NoSchedule"
    }
    app = {
      labels = "role=app"
      taints = ""
    }
  }
}

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  for_each = toset(local.node_group_keys)

  name               = "${var.name_prefix}-eks-${each.key}-node-role"
  description        = "Worker node role for the ${each.key} node group of ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = merge(local.tags, { NodeGroup = each.key })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = {
    for pair in setproduct(local.node_group_keys, local.node_managed_policy_arns) :
    "${pair[0]}:${basename(pair[1])}" => {
      node_group = pair[0]
      policy_arn = pair[1]
    }
  }

  role       = aws_iam_role.node[each.value.node_group].name
  policy_arn = each.value.policy_arn
}

# ---------------------------------------------------------------------------
# Launch templates
#
# One per node group. A launch template is used even for the stock AL2023 AMI so
# that the root volume is gp3 and encrypted, IMDSv2 is mandatory, and the node
# security group is explicit. When image_id and user_data are omitted EKS still
# supplies both; when a Packer AMI is passed in we own the nodeadm bootstrap.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "node" {
  for_each = toset(local.node_group_keys)

  name_prefix = "${var.name_prefix}-${each.key}-"
  description = "Launch template for the ${each.key} node group of ${var.cluster_name}"

  image_id = var.node_ami_id

  user_data = local.use_custom_ami ? base64encode(templatefile("${path.module}/templates/nodeadm-userdata.tftpl", {
    cluster_name          = aws_eks_cluster.this.name
    api_server_endpoint   = aws_eks_cluster.this.endpoint
    certificate_authority = aws_eks_cluster.this.certificate_authority[0].data
    service_cidr          = aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
    node_labels           = local.node_group_kubelet[each.key].labels
    node_taints           = local.node_group_kubelet[each.key].taints
  })) : null

  # The cluster security group must stay attached: naming security groups in a
  # launch template replaces the EKS-managed default rather than adding to it.
  vpc_security_group_ids = [
    aws_security_group.node.id,
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
  ]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Hop limit 1 stops pods on the pod network from reaching IMDS and borrowing
    # the node role. Host-network add-ons (VPC CNI, kube-proxy, EBS CSI node
    # driver) are unaffected; everything else authenticates through IRSA.
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = false
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${var.name_prefix}-${each.key}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = "${var.name_prefix}-${each.key}-node" })
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-${each.key}-lt" })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# System node group
#
# A single on-demand node dedicated to cluster add-ons. The taint keeps
# application pods off it, so a Spot interruption storm in the app group never
# evicts CoreDNS, the ALB controller or the autoscaler itself.
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name_prefix}-system"
  node_role_arn   = aws_iam_role.node["system"].arn
  subnet_ids      = var.private_subnet_ids

  ami_type       = local.ami_type
  capacity_type  = "ON_DEMAND"
  instance_types = [var.system_instance_type]

  scaling_config {
    desired_size = 1
    min_size     = 1
    # max_size 2 only exists so a managed rolling update can surge one node
    # before draining the old one. Steady state is always a single node.
    max_size = 2
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node["system"].id
    version = aws_launch_template.node["system"].latest_version
  }

  labels = {
    role = "system"
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-system" })

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ---------------------------------------------------------------------------
# Application node group
#
# Spot capacity. Cluster Autoscaler owns desired_size after creation, so it is
# ignored here - otherwise every terraform apply would reset the cluster back to
# app_desired_size and evict running pods.
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name_prefix}-app"
  node_role_arn   = aws_iam_role.node["app"].arn
  subnet_ids      = var.private_subnet_ids

  ami_type       = local.ami_type
  capacity_type  = "SPOT"
  instance_types = var.app_instance_types

  scaling_config {
    desired_size = var.app_desired_size
    min_size     = var.app_min_size
    max_size     = var.app_max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node["app"].id
    version = aws_launch_template.node["app"].latest_version
  }

  labels = {
    role = "app"
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-app" })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ---------------------------------------------------------------------------
# Cluster Autoscaler discovery tags
#
# Managed node groups do not carry these by default, and the autoscaler's
# --node-group-auto-discovery flag finds nothing without them. propagate_at_launch
# is false: the tags describe the ASG, not the instances.
# ---------------------------------------------------------------------------

resource "aws_autoscaling_group_tag" "app" {
  for_each = local.autoscaler_asg_tags

  autoscaling_group_name = aws_eks_node_group.app.resources[0].autoscaling_groups[0].name

  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = false
  }
}

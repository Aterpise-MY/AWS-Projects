module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  # Public endpoint so kubectl / ArgoCD CLI can reach the API server from your
  # workstation. Restrict cluster_endpoint_public_access_cidrs in production.
  cluster_endpoint_public_access = true

  # Give the identity running Terraform cluster-admin so the kubernetes/helm
  # providers can create namespaces and install ArgoCD immediately after the
  # control plane comes up.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Managed add-ons kept at cluster-managed versions.
  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD"
  }

  eks_managed_node_groups = {
    worker-nodes = {
      instance_types = [var.node_instance_type]

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      labels = {
        role = "worker"
      }

      tags = {
        NodeGroup = "worker-nodes"
      }
    }
  }

  tags = var.tags
}

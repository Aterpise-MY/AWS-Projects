#
# packer/eks-node.pkr.hcl
#
# Bakes a hardened EKS worker-node AMI for the ticketing platform.
#
# Boundary:
#   Packer owns the MACHINE IMAGE. Ansible (invoked below) owns the HOST
#   configuration inside that image. Kubernetes owns the APPLICATION.
#   Nothing in this file installs, configures, or knows about the Laravel app.
#
# Base image: the official AWS EKS-optimized Amazon Linux 2023 arm64 AMI for
# Kubernetes 1.36, owner 602401143452. We do NOT build from a bare AL2023 AMI —
# reproducing kubelet/containerd/nodeadm packaging by hand is a maintenance
# liability with no upside. We take AWS's node image and layer a baseline on it.
#
# Output: an AMI ID written to packer/manifest.json, consumed by Terraform as
# the `node_ami_id` input of `modules/eks`.
#
# arm64 / Graviton only. There is deliberately no multi-arch matrix — the whole
# platform is Graviton, so a second amd64 artifact would be dead weight.
#

packer {
  required_version = ">= 1.11.0"

  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "region" {
  type        = string
  default     = "ap-southeast-1"
  description = "AWS region to build in. Must match the region the EKS cluster runs in — AMIs are regional."
}

variable "kubernetes_version" {
  type        = string
  default     = "1.36"
  description = "EKS minor version. Selects the matching official node AMI family."
}

variable "build_instance_type" {
  type        = string
  default     = "t4g.medium"
  description = "Graviton build instance. Must be arm64 to match the source AMI architecture."
}

variable "name_prefix" {
  type        = string
  default     = "ticketing-dev"
  description = "Resource name prefix, aligned with the Terraform stack."
}

variable "git_sha" {
  type        = string
  default     = "unknown"
  description = "Full 40-char git SHA of the commit this image was built from. CI passes this in with -var."
}

variable "encrypt_boot" {
  type        = bool
  default     = true
  description = "Encrypt the resulting AMI's root snapshot with the account default EBS KMS key."
}

variable "ami_users" {
  type        = list(string)
  default     = []
  description = "Additional AWS account IDs permitted to launch the AMI. Empty means private to the build account."
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  build_timestamp = formatdate("YYYY-MM-DD'T'hh:mm:ssZ", timestamp())
  ami_suffix      = formatdate("YYYYMMDD-hhmmss", timestamp())
  short_sha       = substr(var.git_sha, 0, 7)

  # Standard tag set. Mirrors terraform/dev/providers.tf default_tags plus the
  # per-module Component value (compute), so the AMI shows up in the same cost
  # and cleanup queries as every other resource in the stack.
  common_tags = {
    Project     = "ticketing"
    Environment = "dev"
    ManagedBy   = "packer"
    Component   = "compute"
    AutoDelete  = "true"
    Repository  = "github.com/brendonang/ticketing-platform"
  }
}

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------

source "amazon-ebs" "eks_node" {
  region        = var.region
  instance_type = var.build_instance_type
  ssh_username  = "ec2-user"

  # Verified live on 2026-07-24 in ap-southeast-1:
  #   amazon-eks-node-al2023-arm64-standard-1.36-v20260625 -> ami-04117a932fe8152dc
  source_ami_filter {
    filters = {
      name                = "amazon-eks-node-al2023-arm64-standard-${var.kubernetes_version}-*"
      architecture        = "arm64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      state               = "available"
    }
    owners      = ["602401143452"]
    most_recent = true
  }

  ami_name        = "${var.name_prefix}-eks-node-${var.kubernetes_version}-arm64-${local.ami_suffix}"
  ami_description = "Hardened EKS ${var.kubernetes_version} arm64 node for ${var.name_prefix} (git ${local.short_sha}), from {{ .SourceAMIName }}"
  ami_users       = var.ami_users

  # IMDSv2 required on the build instance and inherited by anything launched
  # from the AMI unless the launch template overrides it.
  imds_support = "v2.0"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = var.encrypt_boot
    delete_on_termination = true
  }

  # Tags applied to the finished AMI.
  # SourceAMI / SourceAMIName come from the AWS builder's template engine — they
  # record exactly which AWS-published image this was derived from, which is the
  # first question asked in any CVE response.
  tags = {
    Name              = "${var.name_prefix}-eks-node-${var.kubernetes_version}-arm64"
    Project           = local.common_tags.Project
    Environment       = local.common_tags.Environment
    ManagedBy         = local.common_tags.ManagedBy
    Component         = local.common_tags.Component
    AutoDelete        = local.common_tags.AutoDelete
    Repository        = local.common_tags.Repository
    SourceAMI         = "{{ .SourceAMI }}"
    SourceAMIName     = "{{ .SourceAMIName }}"
    GitSHA            = var.git_sha
    BuildTimestamp    = local.build_timestamp
    KubernetesVersion = var.kubernetes_version
    Architecture      = "arm64"
  }

  # Same tags on the backing snapshot, so cleanup-old-amis.py can find orphans
  # by tag even if the AMI registration is gone.
  snapshot_tags = {
    Name           = "${var.name_prefix}-eks-node-${var.kubernetes_version}-arm64"
    Project        = local.common_tags.Project
    Environment    = local.common_tags.Environment
    ManagedBy      = local.common_tags.ManagedBy
    Component      = local.common_tags.Component
    AutoDelete     = local.common_tags.AutoDelete
    GitSHA         = var.git_sha
    BuildTimestamp = local.build_timestamp
  }

  # Tags on the throwaway build instance and its transient security group, so a
  # build that dies mid-flight still leaves attributable resources behind.
  run_tags = {
    Name        = "packer-build-${var.name_prefix}-eks-node"
    Project     = local.common_tags.Project
    Environment = local.common_tags.Environment
    ManagedBy   = local.common_tags.ManagedBy
    Component   = local.common_tags.Component
    AutoDelete  = local.common_tags.AutoDelete
    GitSHA      = var.git_sha
  }
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build {
  name    = "eks-node"
  sources = ["source.amazon-ebs.eks_node"]

  # Wait for cloud-init before Ansible touches dnf, otherwise the first task
  # races the AMI's own first-boot package activity and fails on an RPM lock.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo 'Waiting for cloud-init to settle...'",
      "cloud-init status --wait || true",
      "sudo dnf -y install python3 || true",
    ]
  }

  # Packer orchestrates; Ansible configures. Every line of host configuration
  # lives in the roles under ansible/roles/ so the same code can be re-run
  # against a running node for drift correction, not just at bake time.
  provisioner "ansible" {
    playbook_file = "${path.root}/../ansible/playbooks/node-hardening.yml"
    user          = "ec2-user"

    extra_arguments = [
      "--extra-vars", "ansible_python_interpreter=/usr/bin/python3",
      "--extra-vars", "packer_build=true",
      "--extra-vars", "git_sha=${var.git_sha}",
      "--extra-vars", "kubernetes_version=${var.kubernetes_version}",
      "--scp-extra-args", "'-O'",
    ]

    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_NOCOLOR=True",
      "ANSIBLE_CONFIG=${path.root}/../ansible/ansible.cfg",
      # The dynamic aws_ec2 inventory is for day-2 runs against live nodes.
      # During a bake, Packer supplies its own inventory, so force it off.
      "ANSIBLE_INVENTORY_ENABLED=host_list,script,ini,yaml",
    ]
  }

  # Idempotency pass. The same playbook is applied a second time; a correct
  # baseline reports changed=0 here.
  #
  # > Honest caveat: Packer cannot fail a build on "changed" by itself — Ansible
  # > exits 0 whether it changed 40 things or nothing. The CI workflow greps the
  # > Packer log for `changed=0` on this second play and fails the job if it is
  # > not there. Keeping the pass here means a drifting role is caught at bake
  # > time rather than the first time someone re-runs it against a live node.
  provisioner "ansible" {
    playbook_file = "${path.root}/../ansible/playbooks/node-hardening.yml"
    user          = "ec2-user"

    extra_arguments = [
      "--extra-vars", "ansible_python_interpreter=/usr/bin/python3",
      "--extra-vars", "packer_build=true",
      "--extra-vars", "idempotency_check=true",
      "--extra-vars", "git_sha=${var.git_sha}",
      "--extra-vars", "kubernetes_version=${var.kubernetes_version}",
      "--scp-extra-args", "'-O'",
    ]

    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_NOCOLOR=True",
      "ANSIBLE_CONFIG=${path.root}/../ansible/ansible.cfg",
      "ANSIBLE_INVENTORY_ENABLED=host_list,script,ini,yaml",
    ]
  }

  # Strip build-time artefacts so they are not baked into the image.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "sudo dnf clean all",
      "sudo rm -rf /var/cache/dnf/*",
      "sudo rm -rf /var/log/ansible* /home/ec2-user/.ansible /root/.ansible",
      "sudo truncate -s 0 /var/log/cloud-init-output.log || true",
      "sudo rm -f /home/ec2-user/.ssh/authorized_keys || true",
      "sudo rm -f /root/.ssh/authorized_keys || true",
      "sudo rm -f /etc/machine-id && sudo touch /etc/machine-id",
    ]
  }

  # Terraform reads this file to pin modules/eks var.node_ami_id.
  # See scripts/ for the jq expression that extracts the last build's AMI ID.
  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true

    custom_data = {
      git_sha            = var.git_sha
      kubernetes_version = var.kubernetes_version
      region             = var.region
      architecture       = "arm64"
      build_timestamp    = local.build_timestamp
      source_ami         = "{{ .SourceAMI }}"
    }
  }
}

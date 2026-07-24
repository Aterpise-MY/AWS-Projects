###############################################################################
# ECR — two repositories with deliberately different mutability settings.
#
#   <repository_name>        IMMUTABLE  runtime images, tagged with the 40-char git SHA
#   <cache_repository_name>  MUTABLE    BuildKit registry cache manifests
#
# Both use AES256 (S3-managed) encryption and basic scan-on-push. Enhanced
# scanning (Amazon Inspector) is intentionally NOT enabled — it is a
# registry-level setting, is billed per image scanned, and is out of scope here.
###############################################################################

locals {
  tags = merge(var.tags, { Component = "registry" })
}

###############################################################################
# Application repository — IMMUTABLE
###############################################################################

resource "aws_ecr_repository" "app" {
  name = var.repository_name

  # IMMUTABLE is the whole point of SHA-tagged deploys: once
  # <repo>:<git-sha> is pushed it can never be repointed at different bytes,
  # so what a Kubernetes manifest references is what actually runs. It also
  # makes a rollback to an old SHA byte-identical to the original release.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-app"
    Role = "runtime-images"
  })
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  # Rule order matters: ECR evaluates rules by ascending rulePriority and an
  # image is only ever matched by the first rule that applies.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than ${var.untagged_expiry_days} day(s)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the ${var.tagged_image_count} most recent tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.tagged_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

###############################################################################
# BuildKit cache repository — MUTABLE (this is not optional)
###############################################################################

resource "aws_ecr_repository" "cache" {
  name = var.cache_repository_name

  # CRITICAL: this repository MUST be MUTABLE.
  #
  # `docker buildx build --cache-to type=registry,ref=<cache-repo>:<tag>` pushes
  # a cache manifest under a fixed tag and OVERWRITES it on every build — that
  # overwrite is how the cache stays current. Against an IMMUTABLE repository
  # the `--cache-to` push is rejected with an ImageTagAlreadyExistsException.
  # BuildKit treats cache export as best-effort, so the build still SUCCEEDS and
  # only logs a warning; the cache is simply never updated. Every subsequent
  # build then imports the same stale first-ever manifest and rebuilds every
  # layer from scratch. The failure is silent — it shows up as CI build times
  # that quietly regress from ~2 minutes to ~12, with no red pipeline to trace.
  image_tag_mutability = "MUTABLE"

  # Cache manifests are not runnable images; scanning them wastes scan quota
  # and produces findings against layers that never reach a node.
  image_scanning_configuration {
    scan_on_push = false
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-app-cache"
    Role = "buildkit-cache"
  })
}

resource "aws_ecr_lifecycle_policy" "cache" {
  repository = aws_ecr_repository.cache.name

  # Overwriting a cache tag orphans the previous manifest as untagged. Without
  # this rule the cache repository grows unbounded, one full layer set per build.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged cache manifests older than ${var.cache_untagged_expiry_days} day(s)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.cache_untagged_expiry_days
        }
        action = { type = "expire" }
      },
    ]
  })
}

###############################################################################
# Repository policy — pull-only access for the EKS node roles
###############################################################################

data "aws_iam_policy_document" "pull" {
  count = length(var.pull_principal_arns) > 0 ? 1 : 0

  statement {
    sid    = "AllowPullFromCluster"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.pull_principal_arns
    }

    # Pull-only. `ecr:GetAuthorizationToken` is a registry-level action and
    # cannot be granted here — it belongs on the node role's identity policy.
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}

resource "aws_ecr_repository_policy" "app" {
  count = length(var.pull_principal_arns) > 0 ? 1 : 0

  repository = aws_ecr_repository.app.name
  policy     = data.aws_iam_policy_document.pull[0].json
}

resource "aws_ecr_repository_policy" "cache" {
  count = length(var.pull_principal_arns) > 0 ? 1 : 0

  repository = aws_ecr_repository.cache.name
  policy     = data.aws_iam_policy_document.pull[0].json
}

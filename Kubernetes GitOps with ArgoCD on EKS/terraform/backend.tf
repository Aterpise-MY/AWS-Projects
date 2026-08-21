# Remote state backend (recommended for team use).
#
# Uncomment and configure once you have an S3 bucket + DynamoDB lock table.
# Local state is used by default so the stack works out of the box.
#
# terraform {
#   backend "s3" {
#     bucket         = "my-terraform-state-bucket"
#     key            = "gitops-eks/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "terraform-locks"
#     encrypt        = true
#   }
# }

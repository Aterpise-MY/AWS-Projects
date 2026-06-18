region           = "us-east-1"
environment_name = "prod"
vpc_id           = "vpc-0b8ea2c5bf5093847"
private_subnet_ids = [
  "subnet-02cb41c2b5a9f7927",
  "subnet-0360d6b57c9e8ec3f",
]
db_instance_class = "db.t3.medium"
multi_az          = true
common_tags = {
  Environment = "prod"
  ManagedBy   = "terraform"
  Project     = "multitenant-saas"
}

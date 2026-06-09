/**
 * Project CORTEX - DynamoDB Table Configuration
 * 
 * Creates a DynamoDB table to store Telegram dashboard message IDs
 * for the Git Radar module. Uses on-demand billing for cost efficiency.
 */

resource "aws_dynamodb_table" "cortex_radar_state" {
  name           = "${var.project_name}_radar_state"
  billing_mode   = "PAY_PER_REQUEST" # On-demand pricing for variable workloads
  hash_key       = "id"

  attribute {
    name = "id"
    type = "S" # String type
  }

  # Enable point-in-time recovery for data protection
  point_in_time_recovery {
    enabled = true
  }

  # Enable encryption at rest using AWS managed keys
  server_side_encryption {
    enabled = true
  }

  tags = {
    Name        = "${var.project_name}-radar-state"
    Description = "Stores Telegram message IDs for dashboard updates"
    Module      = "GitRadar"
  }
}

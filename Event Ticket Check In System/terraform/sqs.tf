# SQS FIFO queue — decouples API Gateway from email sending; guarantees ordered delivery
resource "aws_sqs_queue" "gmail_sender" {
  name                        = "python-gmail-sender.fifo"
  fifo_queue                  = true
  content_based_deduplication = true

  # Must exceed Lambda timeout (30 s) so a message stays hidden while being processed
  visibility_timeout_seconds = 35

  tags = {
    Name   = "python-gmail-sender"
    Module = "GmailSender"
  }
}

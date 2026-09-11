"""Shared code for the three POS consumer Lambda functions.

The whole `lambda/` tree is zipped into every deployment package (see
`lambda_source_dir` in the Terraform consumer_queue module), so each handler
imports this package the same way in Lambda and in the unit tests:

    from common.processing import process_batch

Keeping the batch loop, the error taxonomy and the idempotency claim in one
place is what makes the three lanes behave identically under failure — the
scenario's requirements R1-R5 are properties of this package, not of any one
handler.
"""

.PHONY: help init plan apply destroy validate format clean

TF_DIR = infrastructure/terraform

# Default target
help:
	@echo "Project CORTEX - Terraform Deployment Commands"
	@echo ""
	@echo "Available targets:"
	@echo "  init      - Initialize Terraform workspace"
	@echo "  validate  - Validate Terraform configuration"
	@echo "  format    - Format Terraform files"
	@echo "  plan      - Generate execution plan"
	@echo "  apply     - Apply infrastructure changes"
	@echo "  destroy   - Destroy all infrastructure"
	@echo "  clean     - Clean Terraform cache and archives"
	@echo "  outputs   - Display Terraform outputs"
	@echo ""

init:
	@echo "🔧 Initializing Terraform..."
	cd $(TF_DIR) && terraform init

validate: init
	@echo "✅ Validating configuration..."
	cd $(TF_DIR) && terraform validate

format:
	@echo "🎨 Formatting Terraform files..."
	cd $(TF_DIR) && terraform fmt -recursive

plan: validate
	@echo "📋 Generating execution plan..."
	cd $(TF_DIR) && terraform plan

apply: validate
	@echo "🚀 Applying infrastructure..."
	cd $(TF_DIR) && terraform apply

destroy:
	@echo "💥 Destroying infrastructure..."
	cd $(TF_DIR) && terraform destroy

outputs:
	@echo "📊 Terraform Outputs:"
	cd $(TF_DIR) && terraform output

clean:
	@echo "🧹 Cleaning Terraform cache..."
	rm -rf $(TF_DIR)/.terraform/
	rm -f $(TF_DIR)/.terraform.lock.hcl
	rm -rf $(TF_DIR)/.terraform/archives/
	@echo "✅ Clean complete"

# Quick deployment (plan + apply with auto-approve)
deploy: validate
	@echo "🚀 Quick deployment (auto-approve)..."
	cd $(TF_DIR) && terraform apply -auto-approve

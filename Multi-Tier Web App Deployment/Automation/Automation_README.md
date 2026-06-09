# Automation Scripts Guide

This folder contains automated scripts to monitor, manage, and maintain the multi-tier web application deployment on AWS.

## Available Scripts

### 1. `health_check.sh` — Complete System Health Monitoring
Performs comprehensive health checks across all AWS resources.

**Purpose:** Monitor all components and verify system health
- VPC and networking (subnets, IGW, NAT gateways)
- Security groups (ALB, Web tier, RDS)
- Application Load Balancer (ALB) status and connectivity
- Target group health (instance registration)
- Auto Scaling Group (ASG) capacity and distribution
- EC2 instances (state, type, availability zones)
- RDS database (status, multi-AZ, backups)
- CloudWatch alarms and metrics
- Scaling policies and activities

**Output:** Detailed text report with timestamp

**Usage:**
```bash
chmod +x health_check.sh
./health_check.sh
```

**Reports Location:** `Automation/reports/health_check_YYYYMMDD_HHMMSS.txt`

---

### 2. `quick_status.sh` — Quick Status Overview
Fast health check for common issues (ALB, ASG, RDS, instances).

**Purpose:** Get a quick status without full diagnostics
- ALB health and connectivity
- ASG capacity and instance count
- RDS availability
- Instance status summary

**Usage:**
```bash
chmod +x quick_status.sh
./quick_status.sh
```

---

### 3. `test_connectivity.sh` — Application Connectivity Tests
Test HTTP/HTTPS connectivity and measure response times.

**Purpose:** Verify the application is reachable and responsive
- HTTP status code check
- Response time measurement
- DNS resolution test
- Basic health endpoint verification

**Usage:**
```bash
chmod +x test_connectivity.sh
./test_connectivity.sh
```

---

### 4. `instance_logs.sh` — Retrieve EC2 Instance Logs
Fetch and display logs from running EC2 instances.

**Purpose:** Troubleshoot instance issues
- System logs from EC2 console
- CloudWatch logs (if enabled)
- Application logs on instances

**Usage:**
```bash
chmod +x instance_logs.sh
./instance_logs.sh [instance-id] [log-type]
```

---

### 5. `scaling_report.sh` — Scaling Activity Analysis
Analyze Auto Scaling Group activity and metrics.

**Purpose:** Understand scaling behavior and performance
- Recent scaling events
- CPU utilization trends
- Alarm history
- Recommendations for threshold adjustment

**Usage:**
```bash
chmod +x scaling_report.sh
./scaling_report.sh
```

---

### 6. `cost_analysis.sh` — Cost Estimation
Calculate estimated AWS monthly costs based on current configuration.

**Purpose:** Track and estimate infrastructure costs
- Compute (EC2, NAT gateways)
- Database (RDS)
- Load balancer (ALB)
- Data transfer and CloudWatch

**Usage:**
```bash
chmod +x cost_analysis.sh
./cost_analysis.sh
```

---

## Quick Start

### Run All Checks
```bash
cd /path/to/Multi-Tier\ Web\ App\ Deployment/Automation
./health_check.sh
```

### Run Quick Status
```bash
./quick_status.sh
```

### View Previous Reports
```bash
ls -la reports/
cat reports/health_check_LATEST.txt
```

---

## Directory Structure

```
Automation/
├── health_check.sh              # Full comprehensive health check
├── quick_status.sh              # Quick status overview
├── test_connectivity.sh         # Application connectivity tests
├── instance_logs.sh             # Retrieve instance logs
├── scaling_report.sh            # Scaling activity analysis
├── cost_analysis.sh             # Cost estimation
├── reports/                     # Auto-generated health check reports
│   ├── health_check_*.txt       # Full text reports
│   └── health_check_*.json      # JSON format reports (if available)
├── logs/                        # Application and instance logs
└── Automation_README.md         # This file
```

---

## Prerequisites

- AWS CLI v2+ installed and configured
- Valid AWS credentials (`aws sts get-caller-identity` works)
- `jq` for JSON parsing (install: `brew install jq` on macOS, `apt-get install jq` on Linux)
- Terraform outputs available (`terraform output` works)
- Bash 4.0+

### Install Dependencies (macOS)
```bash
brew install awscli jq
```

### Install Dependencies (Ubuntu/Debian)
```bash
apt-get update && apt-get install -y awscli jq
```

---

## Configuration

### Environment Variables
Set these to customize script behavior:

```bash
# Specify AWS region (default: us-east-1)
export AWS_REGION="us-east-1"

# Specify project name (default: multitier-webapp)
export PROJECT_NAME="multitier-webapp"

# Enable verbose logging (default: off)
export VERBOSE=1
```

### AWS CLI Configuration
Ensure AWS CLI is configured with proper credentials:

```bash
# Configure credentials
aws configure

# Or use environment variables
export AWS_ACCESS_KEY_ID="your-key"
export AWS_SECRET_ACCESS_KEY="your-secret"
export AWS_DEFAULT_REGION="us-east-1"
```

---

## Monitoring & Alerts

### Schedule Regular Health Checks
```bash
# Add to crontab (check every 30 minutes)
*/30 * * * * /path/to/Automation/health_check.sh >> /path/to/Automation/logs/cron.log 2>&1

# Check every hour
0 * * * * /path/to/Automation/quick_status.sh >> /path/to/Automation/logs/cron.log 2>&1
```

### Monitor Reports
```bash
# Watch latest report
watch -n 30 'tail -30 reports/health_check_*.txt | tail -30'

# Check for failures
grep "FAIL\|ALARM" reports/health_check_*.txt | tail -20
```

---

## Troubleshooting

### Script Fails with "Command not found"
**Issue:** AWS CLI or jq not installed

**Solution:**
```bash
# Check AWS CLI
aws --version

# Check jq
jq --version

# Install if missing (macOS)
brew install awscli jq
```

### "Terraform outputs not found"
**Issue:** Not in the correct directory or Terraform not initialized

**Solution:**
```bash
# Navigate to project root
cd /path/to/Multi-Tier\ Web\ App\ Deployment

# Initialize if needed
terraform init

# Apply Terraform
terraform apply
```

### "AWS credentials invalid"
**Issue:** AWS credentials expired or not configured

**Solution:**
```bash
# Check current credentials
aws sts get-caller-identity

# Reconfigure if needed
aws configure

# Or set environment variables
export AWS_PROFILE="your-profile-name"
```

### Scripts don't execute (Permission denied)
**Solution:**
```bash
chmod +x /path/to/Automation/*.sh
```

---

## Report Examples

### Health Check Report Format
```
Health Check Report Generated: Thu Jun 09 10:30:45 UTC 2026
Project Directory: /Users/brendonang/Code/AWS Project/Multi-Tier Web App Deployment
AWS Region: us-east-1

========================================
AWS Credentials & Configuration
========================================
[PASS] AWS credentials valid
[INFO] Account ID: 123456789012
[INFO] IAM User/Role: arn:aws:iam::123456789012:user/username

========================================
VPC & Networking
========================================
[PASS] VPC found: vpc-0a1b2c3d4e5f6g7h8
[PASS] VPC state is available
[INFO] Active subnets: 4
[PASS] Multi-AZ subnets (public + private) are configured
[PASS] Internet Gateway attached
[INFO] Available NAT Gateways: 2
[PASS] NAT Gateways are available (Multi-AZ redundancy)

...

========================================
SUMMARY
========================================
Overall Status: PASS
Timestamp: Thu Jun 09 10:30:45 UTC 2026

✓ All checks passed
```

---

## Common Issues & Solutions

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| 502 Bad Gateway | Unhealthy targets | Run `./health_check.sh` and check Target Group Health section |
| Instances not scaling | High CPU threshold or cooldown | Run `./scaling_report.sh` to analyze activity |
| Database connection failed | Security group rules | Check RDS Security Group in health check |
| ALB not responding | ALB not active or no healthy targets | Run health check and verify Target Group Health |
| High costs | Inefficient scaling or over-provisioning | Run `./cost_analysis.sh` and adjust ASG parameters |

---

## Performance Tips

1. **Schedule health checks during off-peak hours** to avoid impacting application performance
2. **Run quick_status.sh for frequent checks** instead of full health_check.sh
3. **Archive old reports** to save disk space: `rm reports/health_check_*.txt -older-than-30-days`
4. **Use JSON reports** for automated alerting and parsing

---

## Support & Debugging

### Enable Debug Mode
```bash
# Add to script or run with bash -x
bash -x health_check.sh 2>&1 | tee debug.log
```

### Check Script Dependencies
```bash
# Verify all required tools
command -v aws || echo "AWS CLI not found"
command -v jq || echo "jq not found"
command -v terraform || echo "Terraform not found"
```

### View CloudWatch Logs
```bash
# Check ALB logs
aws logs describe-log-groups --log-group-name-prefix "/aws/elasticloadbalancing"

# Check RDS logs
aws rds describe-db-log-files --db-instance-identifier multitier-webapp-mysql
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-06-09 | Initial release with 6 core scripts |

---

## Contact & Feedback

For issues, suggestions, or improvements to these scripts, refer to the main project README or contact your DevOps team.

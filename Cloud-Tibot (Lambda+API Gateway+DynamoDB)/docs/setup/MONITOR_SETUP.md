# AWS CloudWatch Log Monitor - Quick Start Guide

## Overview

This automation script monitors your **Git Radar Lambda function** logs in real-time and sends **Telegram alerts** whenever errors or exceptions are detected.

---

## 🚀 Quick Start

### 1. Install Python Dependencies

```bash
cd "C:\Users\BrendonAng\Cloud Tibot"
pip install -r requirements-monitor.txt
```

### 2. Set Environment Variables

**Option A: PowerShell (Temporary)**
```powershell
$env:TELEGRAM_TOKEN = "your-telegram-bot-token"
$env:TELEGRAM_CHAT_ID = "your-chat-id"
$env:AWS_REGION = "us-east-1"
$env:LOG_GROUP_NAME = "/aws/lambda/cloud-tibot_git_radar"
```

**Option B: Create `.env` file (Persistent)**
```
TELEGRAM_TOKEN=your-telegram-bot-token
TELEGRAM_CHAT_ID=your-chat-id
AWS_REGION=us-east-1
LOG_GROUP_NAME=/aws/lambda/cloud-tibot_git_radar
```

Then load it:
```bash
# On Windows (PowerShell)
Get-Content .env | ForEach-Object { 
    $parts = $_ -split "="
    if ($parts.Length -eq 2) { 
        [Environment]::SetEnvironmentVariable($parts[0], $parts[1])
    } 
}

# Or use python-dotenv (automatic)
```

### 3. Get Your Telegram Bot Token & Chat ID

1. **Create Telegram Bot** (if you don't have one):
   - Chat with [@BotFather](https://t.me/botfather)
   - `/newbot` → follow prompts → save token

2. **Get Your Chat ID**:
   - Chat with [@userinfobot](https://t.me/userinfobot)
   - It will reply with your `user_id` (use this as `TELEGRAM_CHAT_ID`)

3. **Test Telegram**:
   ```bash
   curl -X POST https://api.telegram.org/bot<TOKEN>/sendMessage \
     -d chat_id=<CHAT_ID> \
     -d text="Test message"
   ```

### 4. Run the Monitor

```bash
python monitor_logs.py
```

**Output:**
```
✅ Connected to: /aws/lambda/cloud-tibot_git_radar
🔍 Starting real-time log monitoring...
📍 Log Group: /aws/lambda/cloud-tibot_git_radar
⏱️  Poll Interval: 2s
📡 Telegram Alerts: ✅ ENABLED
================================================================================
[1] Found 3 new event(s)
🔵 [2026-02-09 12:34:56] [GIT RADAR] Received event: ...
🟢 [2026-02-09 12:34:57] SUCCESS: Telegram message sent successfully, message_id=123
🔵 [2026-02-09 12:34:58] [GIT RADAR] Routing to push handler
```

---

## 📋 Usage Examples

### Monitor with custom poll interval (1 second)
```bash
python monitor_logs.py --interval 1
```

### Monitor a different Lambda function
```bash
python monitor_logs.py --log-group /aws/lambda/cloud-tibot_auto_remediator
```

### Test mode (run for 5 iterations then exit)
```bash
python monitor_logs.py --iterations 5
```

### Monitor in different region
```bash
python monitor_logs.py --region us-west-2
```

---

## 🔴 Error Detection

The monitor automatically alerts on:

| Pattern | Example | Alert Level |
|---------|---------|-------------|
| `[GIT RADAR] EXCEPTION` | Import error, API failure | 🚨 ERROR |
| `[GIT RADAR] ERROR` | Configuration issue | 🚨 ERROR |
| `Telegram send FAILED` | Telegram API error | 🚨 ERROR |
| `Copilot API error` | GitHub Copilot service down | 🚨 ERROR |
| `ImportError` | Missing package | 🚨 ERROR |

**Success Patterns** (logged but no alert):
- `Telegram message sent successfully`
- `Review comment posted`
- `Workflow run re-triggered`

---

## 🎛️ Advanced Configuration

### Customize Error Patterns

Edit `monitor_logs.py` and modify the `ERROR_PATTERNS` list:

```python
ERROR_PATTERNS = [
    "[GIT RADAR] EXCEPTION",
    "Your custom pattern here",
    "Another pattern",
]
```

### Filter by Specific Log Stream

To monitor only a specific Lambda execution stream:

```bash
# Modify the monitor to filter streams
# In the get_log_streams() method, add:
# return [stream for stream in streams if "2026-02-09" in stream]
```

### Run as Background Service (Windows)

Create a batch file `start_monitor.bat`:
```batch
@echo off
cd "C:\Users\BrendonAng\Cloud Tibot"
python monitor_logs.py
pause
```

Then schedule with **Task Scheduler**:
1. Create Basic Task → "Monitor Git Radar Logs"
2. Trigger: At Startup
3. Action: Run `start_monitor.bat`
4. Enable: "Run whether user is logged in or not"

### Run as Systemd Service (Linux/Mac)

Create `/etc/systemd/system/cortex-log-monitor.service`:
```ini
[Unit]
Description=CORTEX Git Radar Log Monitor
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/cloud-tibot
ExecStart=/usr/bin/python3 monitor_logs.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl enable cortex-log-monitor
sudo systemctl start cortex-log-monitor
sudo systemctl status cortex-log-monitor
```

---

## 🔍 Troubleshooting

### ❌ "Log group not found"
```
❌ Error: Log group '/aws/lambda/cloud-tibot_git_radar' not found.
```
**Fix:** Verify log group exists:
```bash
aws logs describe-log-groups --region us-east-1
```

### ❌ "Telegram API failed (401)"
```
❌ Telegram API failed (401): Unauthorized
```
**Fix:** Check your `TELEGRAM_TOKEN`:
```bash
echo $env:TELEGRAM_TOKEN
```

### ❌ "AWS credentials not configured"
```
botocore.exceptions.NoCredentialsError
```
**Fix:** Configure AWS credentials:
```powershell
aws configure
# Or set env vars:
$env:AWS_ACCESS_KEY_ID = "..."
$env:AWS_SECRET_ACCESS_KEY = "..."
```

### ⚠️ "No new events" (script seems stuck)
This is normal if there's no activity in the Lambda. The script is polling correctly. Send a test GitHub push to generate events:
```bash
curl -X POST https://evn3cc72mb.execute-api.us-east-1.amazonaws.com/webhook/github \
  -H "X-GitHub-Event: push" \
  -H "Content-Type: application/json" \
  -d '{"ref": "refs/heads/main", "commits": []}'
```

---

## 📊 Log Analysis Tips

### View recent logs directly
```bash
aws logs tail /aws/lambda/cloud-tibot_git_radar --follow
```

### Search for specific pattern
```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/cloud-tibot_git_radar \
  --filter-pattern "[GIT RADAR] EXCEPTION"
```

### Export logs to file
```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/cloud-tibot_git_radar \
  --start-time $(date -d '1 hour ago' +%s)000 \
  --query 'events[].message' \
  > git_radar_logs.txt
```

---

## 📞 Support

- **GitHub Issues**: [cloud-tibot/issues](https://github.com/yourusername/cloud-tibot)
- **AWS CloudWatch Docs**: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs
- **Telegram Bot API**: https://core.telegram.org/bots/api

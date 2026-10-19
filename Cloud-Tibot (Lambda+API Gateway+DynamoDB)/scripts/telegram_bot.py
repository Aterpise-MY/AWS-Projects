#!/usr/bin/env python3
"""
🤖 DND Platform Telegram Bot Integration
Monitors GitHub events and sends real-time updates to Telegram
Integrates with Lambda functions for serverless operations
"""

import os
import json
import requests
from typing import Dict, List, Any
from datetime import datetime


class TelegramBot:
    """Telegram Bot for DND Platform notifications"""
    
    def __init__(self, token: str, chat_id: str):
        self.token = token
        self.chat_id = chat_id
        self.base_url = f"https://api.telegram.org/bot{token}"
    
    def send_message(self, text: str, parse_mode: str = "Markdown", 
                    disable_preview: bool = True, topic_id: str = "") -> Dict:
        """Send a message to Telegram
        
        Args:
            text: Message text
            parse_mode: Parse mode (Markdown/HTML)
            disable_preview: Disable link preview
            topic_id: Forum topic thread ID for routing to specific topics
        """
        url = f"{self.base_url}/sendMessage"
        payload = {
            "chat_id": self.chat_id,
            "text": text,
            "parse_mode": parse_mode,
            "disable_web_page_preview": disable_preview
        }
        
        # Route to specific forum topic if configured
        if topic_id:
            payload["message_thread_id"] = int(topic_id)
        
        try:
            response = requests.post(url, json=payload, timeout=10)
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            print(f"❌ Failed to send Telegram message: {e}")
            return {"ok": False, "error": str(e)}
    
    def send_buttons(self, text: str, buttons: List[List[Dict]], topic_id: str = "") -> Dict:
        """Send message with inline buttons"""
        url = f"{self.base_url}/sendMessage"
        payload = {
            "chat_id": self.chat_id,
            "text": text,
            "parse_mode": "Markdown",
            "reply_markup": {
                "inline_keyboard": buttons
            }
        }
        
        # Route to specific forum topic if configured
        if topic_id:
            payload["message_thread_id"] = int(topic_id)
        
        try:
            response = requests.post(url, json=payload, timeout=10)
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            print(f"❌ Failed to send buttons: {e}")
            return {"ok": False, "error": str(e)}


class DndPlatformNotifier:
    """High-level notification handler for DND Platform events"""
    
    def __init__(self, bot: TelegramBot):
        self.bot = bot
    
    def notify_pr_opened(self, pr_data: Dict) -> None:
        """Notify when a new PR is opened"""
        title = pr_data.get("title", "Untitled PR")
        number = pr_data.get("number", "?")
        author = pr_data.get("user", {}).get("login", "Unknown")
        url = pr_data.get("html_url", "")
        additions = pr_data.get("additions", 0)
        deletions = pr_data.get("deletions", 0)
        files = pr_data.get("changed_files", 0)
        
        message = f"""🎲 *DND Platform - New Pull Request*

*PR #{number}*: {title}
👤 Author: @{author}

*Changes:*
➕ {additions} additions
➖ {deletions} deletions
📁 {files} files changed

🔗 [Review PR]({url})

⏳ _Waiting for CI/CD checks..._
"""
        
        buttons = [
            [
                {"text": "👁️ View PR", "url": url},
                {"text": "✅ Approve", "callback_data": f"approve_{number}"}
            ],
            [
                {"text": "💬 Comment", "url": f"{url}#issuecomment-form"},
                {"text": "🔄 Re-run CI", "callback_data": f"rerun_{number}"}
            ]
        ]
        
        self.bot.send_buttons(message, buttons)
    
    def notify_pr_merged(self, pr_data: Dict) -> None:
        """Notify when a PR is merged"""
        title = pr_data.get("title", "Untitled PR")
        number = pr_data.get("number", "?")
        merger = pr_data.get("merged_by", {}).get("login", "Unknown")
        branch = pr_data.get("base", {}).get("ref", "main")
        
        message = f"""✅ *PR Merged Successfully!*

*PR #{number}*: {title}
👤 Merged by: @{merger}
🌿 Branch: `{branch}`

🚀 Deployment will start automatically...
"""
        
        self.bot.send_message(message)
    
    def notify_deployment_start(self, environment: str, commit_sha: str) -> None:
        """Notify when deployment starts"""
        message = f"""🚀 *Deployment Started*

📍 Environment: `{environment}`
📝 Commit: `{commit_sha[:7]}`
⏰ Started: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}

🔄 _Deploying infrastructure and Lambda functions..._
"""
        
        self.bot.send_message(message)
    
    def notify_deployment_success(self, environment: str, duration: str, 
                                  endpoints: Dict) -> None:
        """Notify when deployment succeeds"""
        api_url = endpoints.get("api_gateway", "N/A")
        frontend_url = endpoints.get("frontend", "N/A")
        
        message = f"""✅ *Deployment Successful!*

📍 Environment: `{environment}`
⏱️ Duration: {duration}

*Endpoints:*
🔗 API: `{api_url}`
🌐 Frontend: {frontend_url}

🧪 Running smoke tests...
"""
        
        self.bot.send_message(message)
    
    def notify_deployment_failure(self, environment: str, error: str, 
                                  workflow_url: str) -> None:
        """Notify when deployment fails"""
        message = f"""❌ *Deployment Failed!*

📍 Environment: `{environment}`
⚠️ Error: {error[:200]}...

🔗 [View Workflow Logs]({workflow_url})

🔧 _Action required: Check logs and retry_
"""
        
        buttons = [[
            {"text": "📋 View Logs", "url": workflow_url},
            {"text": "🔄 Retry Deployment", "callback_data": "retry_deploy"}
        ]]
        
        self.bot.send_buttons(message, buttons)
    
    def notify_lambda_error(self, function_name: str, error: str, 
                           cloudwatch_url: str) -> None:
        """Notify when a Lambda function errors"""
        message = f"""⚠️ *Lambda Function Error*

⚡ Function: `{function_name}`
🐛 Error: {error[:300]}

🔗 [CloudWatch Logs]({cloudwatch_url})

🔍 _Check logs for stack trace_
"""
        
        self.bot.send_message(message)
    
    def notify_character_created(self, character_name: str, user: str) -> None:
        """Notify when a character is created"""
        message = f"""🎭 *New Character Created!*

⚔️ Character: *{character_name}*
👤 Created by: @{user}

✅ Saved to DynamoDB successfully
📊 Character data synced to frontend
"""
        
        self.bot.send_message(message)
    
    def notify_pdf_processing(self, filename: str, status: str) -> None:
        """Notify about PDF processing status"""
        emoji = "✅" if status == "success" else "⚠️"
        
        message = f"""{emoji} *PDF Processing {status.title()}*

📄 File: `{filename}`
🤖 Gemini AI: {status}

{'' if status == 'success' else '⚠️ Check CloudWatch logs for details'}
"""
        
        self.bot.send_message(message)
    
    def send_daily_summary(self, stats: Dict) -> None:
        """Send daily summary of platform activity"""
        message = f"""📊 *DND Platform Daily Summary*

📅 Date: {datetime.utcnow().strftime('%Y-%m-%d')}

*Activity:*
👥 New Users: {stats.get('new_users', 0)}
🎭 Characters Created: {stats.get('characters_created', 0)}
📄 PDFs Processed: {stats.get('pdfs_processed', 0)}
🎮 Active Campaigns: {stats.get('active_campaigns', 0)}

*Infrastructure:*
⚡ Lambda Invocations: {stats.get('lambda_invocations', 0):,}
💾 DynamoDB Operations: {stats.get('db_operations', 0):,}
💰 Estimated Cost: ${stats.get('estimated_cost', 0):.2f}

*Performance:*
⏱️ Avg API Response: {stats.get('avg_response_time', 0)}ms
✅ Success Rate: {stats.get('success_rate', 0):.1f}%
"""
        
        self.bot.send_message(message)


def lambda_handler(event, context):
    """
    AWS Lambda handler for processing GitHub webhooks
    and sending Telegram notifications
    """
    
    # Get environment variables
    telegram_token = os.environ.get('TELEGRAM_BOT_TOKEN')
    chat_id = os.environ.get('TELEGRAM_CHAT_ID')
    
    if not telegram_token or not chat_id:
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Missing Telegram credentials'})
        }
    
    # Initialize bot
    bot = TelegramBot(telegram_token, chat_id)
    notifier = DndPlatformNotifier(bot)
    
    # Parse event
    try:
        if isinstance(event.get('body'), str):
            body = json.loads(event['body'])
        else:
            body = event.get('body', {})
        
        event_type = event.get('headers', {}).get('X-GitHub-Event', 'unknown')
        
        # Handle different GitHub events
        if event_type == 'pull_request':
            action = body.get('action')
            pr_data = body.get('pull_request', {})
            
            if action == 'opened':
                notifier.notify_pr_opened(pr_data)
            elif action == 'closed' and pr_data.get('merged'):
                notifier.notify_pr_merged(pr_data)
        
        elif event_type == 'push':
            ref = body.get('ref', '')
            if ref == 'refs/heads/main':
                commit_sha = body.get('after', '')[:7]
                notifier.notify_deployment_start('production', commit_sha)
        
        elif event_type == 'workflow_run':
            conclusion = body.get('workflow_run', {}).get('conclusion')
            if conclusion == 'success':
                notifier.bot.send_message("✅ *Workflow completed successfully!*")
            elif conclusion == 'failure':
                notifier.bot.send_message("❌ *Workflow failed!* Check logs.")
        
        return {
            'statusCode': 200,
            'body': json.dumps({'message': 'Notification sent'})
        }
        
    except Exception as e:
        print(f"Error processing event: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }


def main():
    """Main function for local testing"""
    # Load from environment or .env file
    telegram_token = os.environ.get('TELEGRAM_BOT_TOKEN')
    chat_id = os.environ.get('TELEGRAM_CHAT_ID')
    
    if not telegram_token or not chat_id:
        print("❌ Missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID")
        print("Set them in environment variables or .env file")
        return
    
    # Initialize bot
    bot = TelegramBot(telegram_token, chat_id)
    notifier = DndPlatformNotifier(bot)
    
    # Test notification
    print("🧪 Testing Telegram bot...")
    result = bot.send_message("🎲 *DND Platform Bot is Online!*\n\nReady to send notifications ✅")
    
    if result.get('ok'):
        print("✅ Test message sent successfully!")
    else:
        print(f"❌ Failed to send test message: {result.get('error')}")


if __name__ == "__main__":
    main()

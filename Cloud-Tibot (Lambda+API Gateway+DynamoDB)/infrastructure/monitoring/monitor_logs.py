#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CORTEX CloudWatch Log Monitor
Real-time monitoring for all Lambda functions with Telegram alerts.

Usage:
    python monitor_logs.py --function git_radar --follow
    python monitor_logs.py --function all --errors-only
    python monitor_logs.py --function git_radar --search "Telegram" --minutes 60
    
Environment Variables (Optional):
    TELEGRAM_TOKEN     - Enable Telegram alerts
    TELEGRAM_CHAT_ID   - Telegram chat for alerts
"""

import json
import os
import sys
import time
import boto3
import urllib3
import argparse
from datetime import datetime, timedelta
from typing import Optional, List, Dict, Set
from collections import deque

# Fix Windows console encoding for emoji support
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except AttributeError:
        import codecs
        sys.stdout = codecs.getwriter('utf-8')(sys.stdout.buffer, 'strict')

# ============================================================================
# Configuration
# ============================================================================

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
TELEGRAM_TOKEN = os.environ.get("TELEGRAM_TOKEN")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID")
TELEGRAM_TOPIC_GUARDIAN_ALERT = os.environ.get("TELEGRAM_TOPIC_GUARDIAN_ALERT", "")

# All available log groups
LOG_GROUPS = {
    "git_radar": "/aws/lambda/cloud-tibot_git_radar",
    "auto_remediator": "/aws/lambda/cloud-tibot_auto_remediator",
    "finops_sentinel": "/aws/lambda/cloud-tibot_finops_sentinel",
    "api_gateway": "/aws/apigateway/cloud-tibot-chatops-api",
}

# Terminal colors
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'


# ============================================================================
# CloudWatch Log Monitor with Multi-Function Support
# ============================================================================

class LogMonitor:
    """Enhanced CloudWatch log monitor with multi-function support."""

    def __init__(self, region: str = "us-east-1"):
        self.region = region
        self.logs_client = boto3.client("logs", region_name=region)
        self.http = urllib3.PoolManager()
        self.seen_events: Set[str] = set()

    def send_telegram_alert(self, message: str):
        """Send alert via Telegram using urllib3."""
        if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID:
            return

        url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
        payload = {
            "chat_id": TELEGRAM_CHAT_ID,
            "text": f"🚨 *CloudWatch Alert*\n\n{message[:4000]}",
            "parse_mode": "Markdown",
            "disable_web_page_preview": True,
        }

        # Route to Guardian Alert topic if configured
        if TELEGRAM_TOPIC_GUARDIAN_ALERT:
            payload["message_thread_id"] = int(TELEGRAM_TOPIC_GUARDIAN_ALERT)

        try:
            response = self.http.request(
                "POST", url,
                body=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            if response.status == 200:
                print(f"{Colors.GREEN}✅ Telegram alert sent{Colors.ENDC}")
            else:
                print(f"{Colors.YELLOW}⚠️  Telegram failed: {response.status}{Colors.ENDC}")
        except Exception as e:
            print(f"{Colors.YELLOW}⚠️  Telegram error: {e}{Colors.ENDC}")

    def format_log_entry(self, event: dict, errors_only: bool = False) -> Optional[str]:
        """Format and color-code log entry."""
        message = event.get('message', '').strip()
        timestamp = datetime.fromtimestamp(event['timestamp'] / 1000).strftime('%H:%M:%S')

        # Skip non-errors if errors_only mode
        if errors_only:
            error_keywords = ['ERROR', 'Exception', 'EXCEPTION', 'Traceback', 'FAILED', 'error:']
            if not any(kw in message for kw in error_keywords):
                return None

        # Color coding based on content
        if 'ERROR' in message or 'Exception' in message or 'FAILED' in message:
            color, icon = Colors.RED, "❌"
        elif 'WARNING' in message or 'WARN' in message:
            color, icon = Colors.YELLOW, "⚠️"
        elif '[GIT RADAR]' in message:
            color, icon = Colors.CYAN, "📡"
        elif 'SUCCESS' in message or '✅' in message:
            color, icon = Colors.GREEN, "✅"
        else:
            color, icon = Colors.ENDC, "📝"

        return f"{color}[{timestamp}] {icon} {message}{Colors.ENDC}"

    def tail_logs(self, log_group: str, follow: bool = False, errors_only: bool = False, limit: int = 50):
        """Tail CloudWatch logs (like tail -f)."""
        print(f"\n{Colors.HEADER}{Colors.BOLD}{'='*80}")
        print(f"Monitoring: {log_group}")
        print(f"Mode: {'Follow (live)' if follow else 'Recent logs'}")
        print(f"Filter: {'Errors only' if errors_only else 'All logs'}")
        print(f"{'='*80}{Colors.ENDC}\n")

        start_time = int((datetime.now() - timedelta(minutes=5)).timestamp() * 1000)
        
        try:
            while True:
                try:
                    response = self.logs_client.filter_log_events(
                        logGroupName=log_group,
                        startTime=start_time,
                        limit=limit,
                    )

                    events = response.get('events', [])
                    new_count = 0

                    for event in events:
                        event_id = event['eventId']
                        if event_id in self.seen_events:
                            continue
                        
                        self.seen_events.add(event_id)
                        new_count += 1

                        formatted = self.format_log_entry(event, errors_only)
                        if formatted:
                            print(formatted)

                            # Alert on errors
                            if 'ERROR' in event['message'] or 'Exception' in event['message']:
                                self.send_telegram_alert(
                                    f"*Log:* `{log_group.split('/')[-1]}`\n"
                                    f"*Time:* {datetime.fromtimestamp(event['timestamp']/1000).isoformat()}\n"
                                    f"```\n{event['message'][:3000]}\n```"
                                )

                    if events:
                        start_time = max(e['timestamp'] for e in events) + 1

                    if not follow:
                        if new_count == 0:
                            print(f"{Colors.YELLOW}No new logs found.{Colors.ENDC}")
                        break

                    time.sleep(2)

                except self.logs_client.exceptions.ResourceNotFoundException:
                    print(f"{Colors.RED}❌ Log group not found: {log_group}{Colors.ENDC}")
                    break

        except KeyboardInterrupt:
            print(f"\n{Colors.GREEN}✅ Monitoring stopped.{Colors.ENDC}")

    def search_logs(self, log_group: str, query: str, minutes: int = 30):
        """Search logs for specific text."""
        print(f"\n{Colors.HEADER}Searching '{query}' in {log_group} (last {minutes} min)...{Colors.ENDC}\n")

        start_time = int((datetime.now() - timedelta(minutes=minutes)).timestamp() * 1000)

        try:
            response = self.logs_client.filter_log_events(
                logGroupName=log_group,
                startTime=start_time,
                filterPattern=query,
                limit=100,
            )

            events = response.get('events', [])
            
            if not events:
                print(f"{Colors.YELLOW}No matches found.{Colors.ENDC}")
                return

            print(f"{Colors.GREEN}Found {len(events)} matching entries:{Colors.ENDC}\n")
            
            for event in events:
                formatted = self.format_log_entry(event)
                if formatted:
                    print(formatted)

        except Exception as e:
            print(f"{Colors.RED}Search failed: {e}{Colors.ENDC}")

    def get_error_summary(self, log_group: str, hours: int = 24):
        """Get error statistics for the last N hours."""
        print(f"\n{Colors.HEADER}Error Summary for {log_group} (last {hours}h):{Colors.ENDC}\n")

        start_time = int((datetime.now() - timedelta(hours=hours)).timestamp() * 1000)

        try:
            response = self.logs_client.filter_log_events(
                logGroupName=log_group,
                startTime=start_time,
                filterPattern='?ERROR ?Exception ?FAILED',
                limit=1000,
            )

            events = response.get('events', [])
            
            if not events:
                print(f"{Colors.GREEN}✅ No errors in the last {hours} hours!{Colors.ENDC}")
                return

            # Categorize errors
            error_types = {}
            for event in events:
                msg = event['message']
                
                if 'ERROR' in msg:
                    error_type = "ERROR"
                elif 'Exception' in msg:
                    import re
                    match = re.search(r'(\w+Exception|\w+Error)', msg)
                    error_type = match.group(1) if match else "Exception"
                elif 'FAILED' in msg:
                    error_type = "FAILED"
                else:
                    error_type = "Unknown"

                error_types[error_type] = error_types.get(error_type, 0) + 1

            print(f"{Colors.RED}Total errors: {len(events)}{Colors.ENDC}\n")
            print(f"{Colors.BOLD}Breakdown:{Colors.ENDC}")
            for err_type, count in sorted(error_types.items(), key=lambda x: x[1], reverse=True):
                print(f"  {Colors.YELLOW}• {err_type}: {count}{Colors.ENDC}")

        except Exception as e:
            print(f"{Colors.RED}Failed to get summary: {e}{Colors.ENDC}")


# ============================================================================
# CLI
# ============================================================================

def main():
    """Main entry point with enhanced CLI."""
    parser = argparse.ArgumentParser(
        description="Monitor AWS CloudWatch logs for CORTEX Lambda functions",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Follow logs in real-time
  python monitor_logs.py --function git_radar --follow

  # Show only errors
  python monitor_logs.py --function auto_remediator --errors-only

  # Search for specific text
  python monitor_logs.py --function git_radar --search "Telegram" --minutes 60

  # Get error summary
  python monitor_logs.py --function all --summary --hours 24

  # Monitor all functions
  python monitor_logs.py --function all --follow --errors-only
        """
    )

    parser.add_argument(
        '--function', '-f',
        choices=['git_radar', 'auto_remediator', 'finops_sentinel', 'api_gateway', 'all'],
        required=True,
        help='Lambda function to monitor'
    )

    parser.add_argument(
        '--follow',
        action='store_true',
        help='Follow logs in real-time (like tail -f)'
    )

    parser.add_argument(
        '--errors-only', '-e',
        action='store_true',
        help='Show only error messages'
    )

    parser.add_argument(
        '--search', '-s',
        type=str,
        help='Search for specific text'
    )

    parser.add_argument(
        '--minutes', '-m',
        type=int,
        default=30,
        help='Time window for search (default: 30)'
    )

    parser.add_argument(
        '--summary',
        action='store_true',
        help='Show error summary'
    )

    parser.add_argument(
        '--hours',
        type=int,
        default=24,
        help='Time window for summary (default: 24)'
    )

    parser.add_argument(
        '--limit', '-l',
        type=int,
        default=50,
        help='Log entries per request (default: 50)'
    )

    args = parser.parse_args()

    # Check Telegram credentials
    if TELEGRAM_TOKEN and TELEGRAM_CHAT_ID:
        print(f"{Colors.GREEN}✅ Telegram alerts ENABLED{Colors.ENDC}")
    else:
        print(f"{Colors.YELLOW}⚠️  Telegram alerts DISABLED (set TELEGRAM_TOKEN and TELEGRAM_CHAT_ID){Colors.ENDC}")

    monitor = LogMonitor(region=AWS_REGION)

    # Determine log groups to monitor
    if args.function == 'all':
        log_groups = list(LOG_GROUPS.values())
    else:
        log_groups = [LOG_GROUPS[args.function]]

    # Execute requested operation
    try:
        for log_group in log_groups:
            if args.summary:
                monitor.get_error_summary(log_group, args.hours)
            elif args.search:
                monitor.search_logs(log_group, args.search, args.minutes)
            else:
                monitor.tail_logs(log_group, args.follow, args.errors_only, args.limit)
            
            if len(log_groups) > 1:
                print(f"\n{Colors.BLUE}{'─'*80}{Colors.ENDC}\n")

    except KeyboardInterrupt:
        print(f"\n{Colors.GREEN}✅ Stopped by user{Colors.ENDC}")
    except Exception as e:
        print(f"\n{Colors.RED}❌ Error: {e}{Colors.ENDC}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    main()

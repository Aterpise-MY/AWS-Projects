#!/usr/bin/env python3
"""
Test PR Review Notifier — Send PR #78 review to Telegram topic 118

This script tests the complete workflow:
1. Fetches PR #78 from Aterpise-MY/IB-DND-5e-Platform
2. Analyzes code changes for risk assessment
3. Formats as a rich Telegram message
4. Sends to Topic 118 (🛡️ PR Guardian)

Usage:
    python scripts/test_pr_review_notifier.py

Required environment variables:
    - GITHUB_TOKEN: GitHub API token (gh auth token or personal token)
    - TELEGRAM_TOKEN: Telegram bot token
    - TELEGRAM_CHAT_ID: Telegram forum chat ID (-1003702164149)
"""

import os
import sys
import json
from datetime import datetime

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.pr_review_notifier import PRReviewNotifier, GitHubAPIClient


def print_section(title: str):
    """Print a formatted section header"""
    print("\n" + "=" * 70)
    print(f"  {title}")
    print("=" * 70)


def test_pr_review_notification():
    """Test sending a PR review to Telegram"""
    
    print_section("🛡️ PR Review Notifier — Test")
    
    # ── Load credentials ──────────────────────────────────────────────────────
    print("\n[1/5] Loading credentials...")
    
    github_token = os.environ.get("GITHUB_TOKEN")
    telegram_token = os.environ.get("TELEGRAM_TOKEN")
    telegram_chat_id = os.environ.get("TELEGRAM_CHAT_ID")
    
    if not all([github_token, telegram_token, telegram_chat_id]):
        print("❌ Missing environment variables:")
        if not github_token:
            print("   - GITHUB_TOKEN")
        if not telegram_token:
            print("   - TELEGRAM_TOKEN")
        if not telegram_chat_id:
            print("   - TELEGRAM_CHAT_ID")
        print("\nSet them with:")
        print("   export GITHUB_TOKEN='your-token'")
        print("   export TELEGRAM_TOKEN='123:ABC'")
        print("   export TELEGRAM_CHAT_ID='-1003702164149'")
        return False
    
    print("   ✅ Credentials loaded")
    
    # ── Fetch PR details ──────────────────────────────────────────────────────
    print("\n[2/5] Fetching PR #78 from Aterpise-MY/IB-DND-5e-Platform...")
    
    github_client = GitHubAPIClient(github_token)
    pr_details = github_client.get_pr_details(
        owner="Aterpise-MY",
        repo="IB-DND-5e-Platform",
        pr_number=78
    )
    
    if not pr_details:
        print("   ❌ Failed to fetch PR details")
        return False
    
    print(f"   ✅ PR fetched: '{pr_details.get('title')}'")
    print(f"      Author: {pr_details.get('user', {}).get('login')}")
    print(f"      Changes: +{pr_details.get('additions')} -{pr_details.get('deletions')} ({pr_details.get('changed_files')} files)")
    
    # ── Fetch reviews ─────────────────────────────────────────────────────────
    print("\n[3/5] Fetching PR reviews...")
    
    reviews = github_client.get_pr_reviews(
        owner="Aterpise-MY",
        repo="IB-DND-5e-Platform",
        pr_number=78
    )
    
    print(f"   ✅ Found {len(reviews)} review(s)")
    for i, review in enumerate(reviews, 1):
        print(f"      {i}. {review.get('user', {}).get('login')} — {review.get('state')}")
    
    # ── Initialize notifier ───────────────────────────────────────────────────
    print("\n[4/5] Initializing PR Review Notifier...")
    
    notifier = PRReviewNotifier(github_token, telegram_token, telegram_chat_id)
    print("   ✅ Notifier initialized")
    
    # ── Send notification ─────────────────────────────────────────────────────
    print("\n[5/5] Sending review to Telegram Topic 118...")
    
    success, message = notifier.notify_pr_review(
        owner="Aterpise-MY",
        repo="IB-DND-5e-Platform",
        pr_number=78,
        request_copilot_review=False
    )
    
    print_section("📊 Test Result")
    
    if success:
        print(f"✅ SUCCESS: {message}")
        print("\n💡 Check your Telegram group:")
        print("   - Open the group chat")
        print("   - Click on 'Topics'")
        print("   - View the '🛡️ PR Guardian' topic (118)")
        print("   - You should see the PR review message there")
        return True
    else:
        print(f"❌ FAILED: {message}")
        return False


def test_batch_pr_notifications():
    """Test sending notifications for multiple PRs"""
    
    print_section("🛡️ Batch PR Review Test")
    
    # Load credentials
    github_token = os.environ.get("GITHUB_TOKEN")
    telegram_token = os.environ.get("TELEGRAM_TOKEN")
    telegram_chat_id = os.environ.get("TELEGRAM_CHAT_ID")
    
    if not all([github_token, telegram_token, telegram_chat_id]):
        print("❌ Missing credentials")
        return False
    
    # Initialize notifier
    notifier = PRReviewNotifier(github_token, telegram_token, telegram_chat_id)
    
    # Test PRs to notify
    test_prs = [
        {"number": 78, "label": "[FE-14] Condition tracker"},
        # Add more PRs as needed
    ]
    
    results = []
    
    for pr_info in test_prs:
        pr_num = pr_info["number"]
        label = pr_info["label"]
        
        print(f"\n📤 Sending PR #{pr_num}: {label}...")
        
        success, message = notifier.notify_pr_review(
            owner="Aterpise-MY",
            repo="IB-DND-5e-Platform",
            pr_number=pr_num
        )
        
        results.append((pr_num, label, success, message))
        
        if success:
            print(f"   ✅ Sent")
        else:
            print(f"   ❌ Failed: {message}")
    
    # Summary
    print_section("📊 Batch Summary")
    
    successful = sum(1 for _, _, success, _ in results if success)
    total = len(results)
    
    print(f"\n✅ Successful: {successful}/{total}")
    print(f"❌ Failed: {total - successful}/{total}")
    
    for pr_num, label, success, message in results:
        emoji = "✅" if success else "❌"
        print(f"\n{emoji} PR #{pr_num}: {label}")
        if not success:
            print(f"   {message}")
    
    return successful == total


def test_copilot_review_notification():
    """Test sending a Copilot-specific review to Telegram"""
    
    print_section("🤖 Copilot Code Review Test")
    
    # ── Load credentials ──────────────────────────────────────────────────────
    print("\n[1/4] Loading credentials...")
    
    github_token = os.environ.get("GITHUB_TOKEN")
    telegram_token = os.environ.get("TELEGRAM_TOKEN")
    telegram_chat_id = os.environ.get("TELEGRAM_CHAT_ID")
    
    if not all([github_token, telegram_token, telegram_chat_id]):
        print("❌ Missing environment variables")
        return False
    
    print("   ✅ Credentials loaded")
    
    # ── Initialize notifier ───────────────────────────────────────────────────
    print("\n[2/4] Initializing notifier...")
    
    notifier = PRReviewNotifier(github_token, telegram_token, telegram_chat_id)
    print("   ✅ Notifier initialized")
    
    # ── Check for Copilot review ──────────────────────────────────────────────
    print("\n[3/4] Checking for Copilot reviews...")
    
    github_client = GitHubAPIClient(github_token)
    copilot_review = github_client.get_copilot_review(
        owner="Aterpise-MY",
        repo="IB-DND-5e-Platform",
        pr_number=99
    )
    
    if not copilot_review:
        print("   ⚠️  No Copilot review found for PR #99")
        print("   (This is expected if Copilot hasn't reviewed this PR yet)")
        return True  # Not a failure, just not ready
    
    print(f"   ✅ Copilot review found")
    print(f"      State: {copilot_review.get('state')}")
    print(f"      Reviewer: {copilot_review.get('user', {}).get('login')}")
    
    # ── Send Copilot review notification ──────────────────────────────────────
    print("\n[4/4] Sending Copilot review to Telegram Topic 118...")
    
    success, message = notifier.notify_copilot_review(
        owner="Aterpise-MY",
        repo="IB-DND-5e-Platform",
        pr_number=99
    )
    
    print_section("📊 Copilot Review Test Result")
    
    if success:
        print(f"✅ SUCCESS: {message}")
        print("\n💡 Check your Telegram group:")
        print("   - Open the group chat")
        print("   - Click on 'Topics'")
        print("   - View the '🛡️ PR Guardian' topic (118)")
        print("   - You should see the Copilot review message there")
        return True
    else:
        print(f"❌ FAILED: {message}")
        return False


def main():
    """Main entry point"""
    
    import argparse
    
    parser = argparse.ArgumentParser(
        description="Test PR Review Notifier — Send PR reviews to Telegram",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Test single PR notification
  python scripts/test_pr_review_notifier.py

  # Test Copilot review
  python scripts/test_pr_review_notifier.py --copilot

  # Test batch notifications
  python scripts/test_pr_review_notifier.py --batch

  # Test with verbose output
  python scripts/test_pr_review_notifier.py --verbose
        """
    )
    
    parser.add_argument(
        "--batch", action="store_true",
        help="Test batch PR notifications"
    )
    parser.add_argument(
        "--copilot", action="store_true",
        help="Test Copilot-specific review detection"
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Enable verbose output"
    )
    parser.add_argument(
        "--pr", type=int, default=78,
        help="PR number to test (default: 78)"
    )
    
    args = parser.parse_args()
    
    if args.batch:
        success = test_batch_pr_notifications()
    elif args.copilot:
        success = test_copilot_review_notification()
    else:
        success = test_pr_review_notification()
    
    print_section("✅ Test Complete" if success else "❌ Test Failed")
    
    exit(0 if success else 1)


if __name__ == "__main__":
    main()

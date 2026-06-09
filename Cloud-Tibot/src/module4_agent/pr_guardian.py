#!/usr/bin/env python3
"""
Project CORTEX - Module 4: PR Guardian Agent
AI-Powered Pull Request Security & Code Quality Scanner

Runs in GitHub Actions on every PR. Uses OpenAI to analyze code diffs
for security flaws, bugs, and performance issues. Reports findings back
to CORTEX Git Radar (Module 2) via webhook.

Environment Variables Required:
- GITHUB_TOKEN: GitHub Actions token for API access
- OPENAI_API_KEY: OpenAI API key for LLM analysis
- CORTEX_RADAR_WEBHOOK: Module 2 webhook URL (from Terraform output)
- GITHUB_REPOSITORY: Auto-set by GitHub Actions
- GITHUB_EVENT_PATH: Auto-set by GitHub Actions (PR event JSON)
"""

import os
import sys
import json
import requests
from typing import Dict, List, Optional

try:
    from github import Github, Auth
    from openai import OpenAI
except ImportError as e:
    print(f"❌ Missing required dependency: {e}")
    print("Install with: pip install PyGithub openai requests")
    sys.exit(1)


class CortexGuardian:
    """CORTEX-Guardian: AI-powered PR security and quality analyzer"""
    
    SYSTEM_PROMPT = """You are CORTEX-Guardian, an elite code security and quality analyst.

Your mission: Analyze Pull Request code diffs for:
1. 🔐 Security vulnerabilities (SQL injection, XSS, secrets exposure, etc.)
2. 🐛 Potential bugs and logic errors
3. ⚡ Performance issues and anti-patterns
4. 📐 Code quality concerns (complexity, maintainability)

Be concise and actionable. Prioritize high-severity findings. Format your response as:

**Risk Level**: [🔴 CRITICAL | 🟡 MEDIUM | 🟢 LOW | ✅ CLEAN]

**Findings**:
- [Security/Bug/Performance]: Brief description
- Recommended fix (if needed)

Keep analysis under 300 words."""

    def __init__(self, github_token: str, openai_api_key: str, webhook_url: str):
        """Initialize Guardian with API credentials"""
        self.github = Github(auth=Auth.Token(github_token))
        self.openai = OpenAI(api_key=openai_api_key)
        self.webhook_url = webhook_url
        
        print("🛡️  CORTEX-Guardian initialized")
        print(f"   Webhook: {webhook_url[:50]}...")

    def get_pr_diff(self, repo_name: str, pr_number: int) -> str:
        """Fetch the complete diff for a pull request"""
        print(f"📥 Fetching PR #{pr_number} diff from {repo_name}...")
        
        try:
            repo = self.github.get_repo(repo_name)
            pr = repo.get_pull(pr_number)
            
            # Get list of changed files
            files = pr.get_files()
            
            diff_content = []
            diff_content.append(f"# Pull Request #{pr_number}: {pr.title}\n")
            diff_content.append(f"Branch: {pr.head.ref} → {pr.base.ref}\n")
            diff_content.append(f"Changed files: {pr.changed_files}\n")
            diff_content.append(f"Additions: +{pr.additions} | Deletions: -{pr.deletions}\n\n")
            
            # Collect diffs from changed files
            for file in files:
                diff_content.append(f"\n{'='*60}")
                diff_content.append(f"FILE: {file.filename}")
                diff_content.append(f"Status: {file.status} | +{file.additions} -{file.deletions}")
                diff_content.append(f"{'='*60}\n")
                
                if file.patch:
                    diff_content.append(file.patch)
                else:
                    diff_content.append("(Binary file or no diff available)")
            
            full_diff = "\n".join(diff_content)
            print(f"✅ Retrieved diff: {len(full_diff)} characters, {pr.changed_files} files")
            return full_diff
            
        except Exception as e:
            print(f"❌ Error fetching PR diff: {e}")
            raise

    def analyze_with_llm(self, pr_diff: str) -> Dict[str, str]:
        """Send diff to OpenAI for security and quality analysis"""
        print("🤖 Analyzing code diff with OpenAI...")
        
        # Limit diff size to avoid token limits (first 8000 chars)
        truncated_diff = pr_diff[:8000]
        if len(pr_diff) > 8000:
            truncated_diff += "\n\n[... diff truncated due to length ...]"
        
        try:
            response = self.openai.chat.completions.create(
                model="gpt-4",  # or "gpt-3.5-turbo" for faster/cheaper analysis
                messages=[
                    {"role": "system", "content": self.SYSTEM_PROMPT},
                    {"role": "user", "content": f"Analyze this PR diff:\n\n{truncated_diff}"}
                ],
                max_tokens=500,
                temperature=0.3  # Lower temperature for more consistent analysis
            )
            
            analysis = response.choices[0].message.content.strip()
            print(f"✅ LLM analysis complete: {len(analysis)} chars")
            
            # Determine risk level from response
            risk_level = "🟢 LOW"
            if "🔴 CRITICAL" in analysis or "CRITICAL" in analysis.upper():
                risk_level = "🔴 CRITICAL"
            elif "🟡 MEDIUM" in analysis or "MEDIUM" in analysis.upper():
                risk_level = "🟡 MEDIUM"
            elif "✅ CLEAN" in analysis or "CLEAN" in analysis.upper():
                risk_level = "✅ CLEAN"
            
            return {
                "risk_level": risk_level,
                "analysis": analysis,
                "model": response.model,
                "tokens_used": response.usage.total_tokens
            }
            
        except Exception as e:
            print(f"❌ OpenAI analysis error: {e}")
            raise

    def post_pr_comment(self, repo_name: str, pr_number: int, analysis: str):
        """Post analysis results as a PR comment"""
        print(f"💬 Posting analysis comment to PR #{pr_number}...")
        
        try:
            repo = self.github.get_repo(repo_name)
            pr = repo.get_pull(pr_number)
            
            comment_body = f"""## 🛡️ CORTEX-Guardian PR Analysis

{analysis}

---
*🤖 Automated code review by CORTEX-Guardian | Powered by OpenAI*
"""
            
            pr.create_issue_comment(comment_body)
            print("✅ Comment posted successfully")
            
        except Exception as e:
            print(f"⚠️  Failed to post comment: {e}")
            # Don't fail the entire workflow if commenting fails

    def send_to_cortex_radar(self, pr_number: int, risk_level: str, summary: str, repo_name: str):
        """Send analysis results to CORTEX Git Radar (Module 2) via webhook"""
        print(f"📡 Sending analysis to CORTEX Radar webhook...")
        
        # Determine status emoji
        if "CRITICAL" in risk_level:
            status = "⚠️ CRITICAL RISKS"
        elif "MEDIUM" in risk_level:
            status = "⚠️ Risks Found"
        elif "LOW" in risk_level:
            status = "⚡ Minor Issues"
        else:
            status = "🟢 Clean"
        
        payload = {
            "event": "agent_scan",
            "pr": pr_number,
            "status": status,
            "risk_level": risk_level,
            "summary": summary[:500],  # Limit summary length
            "repository": repo_name,
            "scanner": "CORTEX-Guardian",
            "timestamp": self._get_timestamp()
        }
        
        try:
            response = requests.post(
                self.webhook_url,
                json=payload,
                headers={
                    "Content-Type": "application/json",
                    "User-Agent": "CORTEX-Guardian/1.0"
                },
                timeout=10
            )
            
            print(f"✅ Webhook response: {response.status_code}")
            if response.status_code == 200:
                print(f"   Response body: {response.text[:200]}")
            else:
                print(f"   ⚠️  Non-200 status: {response.text[:200]}")
                
        except Exception as e:
            print(f"❌ Webhook send failed: {e}")
            # Don't fail workflow if webhook fails

    @staticmethod
    def _get_timestamp() -> str:
        """Get current timestamp in ISO format"""
        from datetime import datetime
        return datetime.utcnow().isoformat() + "Z"


def main():
    """Main execution: Load PR event, analyze, report"""
    print("\n" + "="*70)
    print("🛡️  CORTEX-GUARDIAN | Pull Request Security Scanner")
    print("="*70 + "\n")
    
    # ── Load environment variables ──
    github_token = os.getenv("GITHUB_TOKEN")
    openai_api_key = os.getenv("OPENAI_API_KEY")
    webhook_url = os.getenv("CORTEX_RADAR_WEBHOOK")
    repo_name = os.getenv("GITHUB_REPOSITORY")  # e.g., "owner/repo"
    event_path = os.getenv("GITHUB_EVENT_PATH")
    
    # Validate required env vars
    missing = []
    if not github_token:
        missing.append("GITHUB_TOKEN")
    if not openai_api_key:
        missing.append("OPENAI_API_KEY")
    if not webhook_url:
        missing.append("CORTEX_RADAR_WEBHOOK")
    if not repo_name:
        missing.append("GITHUB_REPOSITORY")
    if not event_path:
        missing.append("GITHUB_EVENT_PATH")
    
    if missing:
        print(f"❌ Missing required environment variables: {', '.join(missing)}")
        sys.exit(1)
    
    # ── Load PR event data ──
    print(f"📂 Loading PR event from: {event_path}")
    try:
        with open(event_path, 'r') as f:
            event = json.load(f)
        
        pr_number = event["pull_request"]["number"]
        pr_title = event["pull_request"]["title"]
        pr_user = event["pull_request"]["user"]["login"]
        
        print(f"   PR #{pr_number}: {pr_title}")
        print(f"   Author: @{pr_user}")
        print(f"   Repository: {repo_name}\n")
        
    except Exception as e:
        print(f"❌ Failed to load PR event: {e}")
        sys.exit(1)
    
    # ── Initialize Guardian and analyze ──
    try:
        guardian = CortexGuardian(github_token, openai_api_key, webhook_url)
        
        # Step 1: Fetch PR diff
        pr_diff = guardian.get_pr_diff(repo_name, pr_number)
        
        # Step 2: Analyze with LLM
        result = guardian.analyze_with_llm(pr_diff)
        
        print(f"\n📊 Analysis Results:")
        print(f"   Risk Level: {result['risk_level']}")
        print(f"   Model: {result['model']}")
        print(f"   Tokens: {result['tokens_used']}")
        print(f"\n{result['analysis']}\n")
        
        # Step 3: Post comment on PR
        guardian.post_pr_comment(repo_name, pr_number, result['analysis'])
        
        # Step 4: Send webhook to CORTEX Radar
        guardian.send_to_cortex_radar(
            pr_number=pr_number,
            risk_level=result['risk_level'],
            summary=result['analysis'],
            repo_name=repo_name
        )
        
        print("\n" + "="*70)
        print("✅ CORTEX-Guardian scan complete!")
        print("="*70)
        
        # Exit with non-zero if critical issues found (optional: blocks merge)
        if "CRITICAL" in result['risk_level']:
            print("\n⚠️  CRITICAL issues detected - review required!")
            sys.exit(1)  # Uncomment to block PR merge on critical issues
        
    except Exception as e:
        print(f"\n❌ Guardian execution failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()

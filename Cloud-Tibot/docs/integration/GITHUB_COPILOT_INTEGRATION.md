# 🤖 GitHub Copilot & AI Models Integration Guide

## Overview

This guide shows you **3 options** to integrate AI into CORTEX Guardian for PR scanning:

1. **GitHub Models** (Recommended - FREE!)
2. **OpenAI API** (Current implementation)
3. **Hybrid Approach** (Both)

---

## � Quick Decision Guide

**Choose GitHub Models if:**
- ✅ You want FREE AI analysis
- ✅ You're okay with rate limits (15 req/min, 150/day)
- ✅ You don't need continuous high-volume scanning

**Choose OpenAI if:**
- ✅ You need higher rate limits
- ✅ You want consistent GPT-4 performance
- ✅ You have budget for ~$3-6/month

**Choose Hybrid if:**
- ✅ You want GitHub Models as primary (free)
- ✅ With OpenAI as fallback (reliability)

---

## 🆚 Detailed Comparison

### OpenAI vs GitHub Models vs Hybrid

| Feature | OpenAI API | GitHub Models | Hybrid | GitHub Copilot SDK |
|---------|-----------|---------------|--------|-------------------|
| **Use in GitHub Actions** | ✅ Yes | ✅ Yes | ✅ Yes | ❌ No (VS Code only) |
| **Cost** | ~$0.05/PR | 🆓 Free | ~$0.01/PR | N/A |
| **Authentication** | API Key | GitHub Token | Both | N/A |
| **Models** | GPT-4, GPT-3.5 | GPT-4o, Claude, Llama | Both | N/A |
| **Rate Limits** | High (paid) | 15req/min, 150/day | Combined | N/A |
| **Reliability** | Very High | Medium | Highest | N/A |
| **Setup Complexity** | Easy | Easy | Moderate | N/A |

**Recommendation**: 
- **Start with GitHub Models** (free!)
- **Upgrade to Hybrid** if you hit rate limits

---

## 🚀 Option 1: GitHub Models Integration (Recommended)

### Step 1: Generate GitHub Token

1. Go to: https://github.com/settings/tokens?type=beta
2. Click **"Generate new token"** → **"Generate new token (classic)"**
3. Configure:
   - **Note**: `CORTEX Guardian - GitHub Models`
   - **Expiration**: 90 days (or custom)
   - **Scopes**: Select `repo` (for PR access) and **`model`** (for AI models)
4. Click **"Generate token"**
5. **Copy the token** (you won't see it again!)

### Step 2: Update GitHub Secrets

Go to: **Repository → Settings → Secrets and variables → Actions**

**Update existing secret:**
- **Name**: `GITHUB_TOKEN` (already exists, but Actions token doesn't have `model` scope)
- **Create new**: `GITHUB_MODELS_TOKEN`
- **Value**: Paste your personal access token from Step 1

**Keep existing:**
- `CORTEX_RADAR_WEBHOOK` (still needed for Module 2 webhook)

**Optional (remove if using GitHub Models):**
- `OPENAI_API_KEY` (no longer needed)

### Step 3: Update pr_guardian.py

Replace OpenAI with GitHub Models:

```python
#!/usr/bin/env python3
"""
Project CORTEX - Module 4: PR Guardian Agent (GitHub Models Edition)
Uses GitHub's free AI models instead of OpenAI
"""

import os
import sys
import json
import requests
from typing import Dict, List, Optional

try:
    from github import Github, Auth
except ImportError as e:
    print(f"❌ Missing required dependency: {e}")
    print("Install with: pip install PyGithub requests")
    sys.exit(1)


class CortexGuardian:
    """CORTEX-Guardian: AI-powered PR security analyzer using GitHub Models"""
    
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

    # GitHub Models API endpoint
    GITHUB_MODELS_API = "https://models.inference.ai.azure.com/chat/completions"
    
    # Available models (free via GitHub)
    AVAILABLE_MODELS = {
        "gpt-4o": "gpt-4o",                           # OpenAI GPT-4o (best quality)
        "gpt-4o-mini": "gpt-4o-mini",                 # GPT-4o mini (faster)
        "claude-3.5-sonnet": "claude-3-5-sonnet",     # Anthropic Claude
        "llama-3.1-70b": "meta-llama-3.1-70b-instruct", # Meta Llama
        "phi-3": "phi-3-medium-instruct"              # Microsoft Phi-3
    }

    def __init__(self, github_token: str, webhook_url: str, model: str = "gpt-4o-mini"):
        """Initialize Guardian with GitHub authentication"""
        self.github = Github(auth=Auth.Token(github_token))
        self.github_token = github_token
        self.webhook_url = webhook_url
        self.model = self.AVAILABLE_MODELS.get(model, "gpt-4o-mini")
        
        print("🛡️  CORTEX-Guardian initialized")
        print(f"   AI Model: {self.model}")
        print(f"   Webhook: {webhook_url[:50]}...")

    def get_pr_diff(self, repo_name: str, pr_number: int) -> str:
        """Fetch the complete diff for a pull request"""
        print(f"📥 Fetching PR #{pr_number} diff from {repo_name}...")
        
        try:
            repo = self.github.get_repo(repo_name)
            pr = repo.get_pull(pr_number)
            
            files = pr.get_files()
            
            diff_content = []
            diff_content.append(f"# Pull Request #{pr_number}: {pr.title}\n")
            diff_content.append(f"Branch: {pr.head.ref} → {pr.base.ref}\n")
            diff_content.append(f"Changed files: {pr.changed_files}\n")
            diff_content.append(f"Additions: +{pr.additions} | Deletions: -{pr.deletions}\n\n")
            
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

    def analyze_with_github_models(self, pr_diff: str) -> Dict[str, str]:
        """Send diff to GitHub Models API for security analysis"""
        print(f"🤖 Analyzing code diff with GitHub Models ({self.model})...")
        
        # Limit diff size to avoid token limits
        truncated_diff = pr_diff[:8000]
        if len(pr_diff) > 8000:
            truncated_diff += "\n\n[... diff truncated due to length ...]"
        
        try:
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self.github_token}"
            }
            
            payload = {
                "model": self.model,
                "messages": [
                    {"role": "system", "content": self.SYSTEM_PROMPT},
                    {"role": "user", "content": f"Analyze this PR diff:\n\n{truncated_diff}"}
                ],
                "max_tokens": 500,
                "temperature": 0.3
            }
            
            # Call GitHub Models API
            response = requests.post(
                self.GITHUB_MODELS_API,
                headers=headers,
                json=payload,
                timeout=30
            )
            
            if response.status_code != 200:
                print(f"❌ GitHub Models API error: {response.status_code}")
                print(f"Response: {response.text}")
                raise Exception(f"API returned {response.status_code}: {response.text}")
            
            result = response.json()
            analysis = result["choices"][0]["message"]["content"].strip()
            
            print(f"✅ Analysis complete: {len(analysis)} chars")
            print(f"   Tokens used: {result.get('usage', {}).get('total_tokens', 'N/A')}")
            
            # Determine risk level
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
                "model": self.model,
                "tokens_used": result.get("usage", {}).get("total_tokens", 0)
            }
            
        except Exception as e:
            print(f"❌ GitHub Models analysis error: {e}")
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
*🤖 Automated code review by CORTEX-Guardian | Powered by GitHub Models ({self.model})*
"""
            
            pr.create_issue_comment(comment_body)
            print("✅ Comment posted successfully")
            
        except Exception as e:
            print(f"⚠️  Failed to post comment: {e}")

    def send_to_cortex_radar(self, pr_number: int, risk_level: str, summary: str, repo_name: str):
        """Send analysis results to CORTEX Git Radar via webhook"""
        print(f"📡 Sending analysis to CORTEX Radar webhook...")
        
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
            "summary": summary[:500],
            "repository": repo_name,
            "scanner": "CORTEX-Guardian",
            "model": self.model,
            "timestamp": self._get_timestamp()
        }
        
        try:
            response = requests.post(
                self.webhook_url,
                json=payload,
                headers={
                    "Content-Type": "application/json",
                    "User-Agent": "CORTEX-Guardian/2.0"
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

    @staticmethod
    def _get_timestamp() -> str:
        from datetime import datetime
        return datetime.utcnow().isoformat() + "Z"


def main():
    """Main execution: Load PR event, analyze, report"""
    print("\n" + "="*70)
    print("🛡️  CORTEX-GUARDIAN | Pull Request Security Scanner")
    print("    Powered by GitHub Models (Free AI)")
    print("="*70 + "\n")
    
    # Load environment variables
    github_token = os.getenv("GITHUB_MODELS_TOKEN") or os.getenv("GITHUB_TOKEN")
    webhook_url = os.getenv("CORTEX_RADAR_WEBHOOK")
    repo_name = os.getenv("GITHUB_REPOSITORY")
    event_path = os.getenv("GITHUB_EVENT_PATH")
    model = os.getenv("AI_MODEL", "gpt-4o-mini")  # Default to GPT-4o mini
    
    # Validate
    missing = []
    if not github_token:
        missing.append("GITHUB_TOKEN or GITHUB_MODELS_TOKEN")
    if not webhook_url:
        missing.append("CORTEX_RADAR_WEBHOOK")
    if not repo_name:
        missing.append("GITHUB_REPOSITORY")
    if not event_path:
        missing.append("GITHUB_EVENT_PATH")
    
    if missing:
        print(f"❌ Missing required environment variables: {', '.join(missing)}")
        sys.exit(1)
    
    # Load PR event
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
    
    # Initialize and analyze
    try:
        guardian = CortexGuardian(github_token, webhook_url, model)
        
        # Fetch PR diff
        pr_diff = guardian.get_pr_diff(repo_name, pr_number)
        
        # Analyze with GitHub Models
        result = guardian.analyze_with_github_models(pr_diff)
        
        print(f"\n📊 Analysis Results:")
        print(f"   Risk Level: {result['risk_level']}")
        print(f"   Model: {result['model']}")
        print(f"   Tokens: {result['tokens_used']}")
        print(f"\n{result['analysis']}\n")
        
        # Post comment on PR
        guardian.post_pr_comment(repo_name, pr_number, result['analysis'])
        
        # Send webhook to CORTEX Radar
        guardian.send_to_cortex_radar(
            pr_number=pr_number,
            risk_level=result['risk_level'],
            summary=result['analysis'],
            repo_name=repo_name
        )
        
        print("\n" + "="*70)
        print("✅ CORTEX-Guardian scan complete!")
        print("="*70)
        
        # Exit with error if critical issues found (optional)
        # if "CRITICAL" in result['risk_level']:
        #     sys.exit(1)
        
    except Exception as e:
        print(f"\n❌ Guardian execution failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()

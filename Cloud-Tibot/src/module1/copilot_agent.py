"""
Copilot AI Agent - Shared helper for GitHub Copilot SDK integration.
Uses GitHub Copilot's chat completions API as an AI agent for
automated CI/CD remediation and cloud infrastructure fixes.

AUTHENTICATION: GitHub App JWT Flow
===================================
This module uses GitHub App authentication with JSON Web Tokens (JWT).
The Lambda receives App ID, Installation ID, and Private Key via environment variables.
A fresh installation access token is generated for each request.

Required Environment Variables:
- GITHUB_APP_ID: Your GitHub App ID
- GITHUB_APP_INSTALLATION_ID: Installation ID for your account/org
- GITHUB_APP_PRIVATE_KEY: Private key in PEM format
"""

import json
import urllib3
import os
import jwt
import time
from typing import Optional

# GitHub Copilot Models API endpoint
COPILOT_API_URL = "https://api.githubcopilot.com/chat/completions"
COPILOT_MODEL = "gpt-4o"  # Copilot's recommended model


def get_installation_token(app_id: str, installation_id: str, private_key: str) -> str:
    """
    Generate a GitHub App installation access token using JWT authentication.
    
    Args:
        app_id: GitHub App ID
        installation_id: GitHub App Installation ID
        private_key: Private key in PEM format
        
    Returns:
        str: Installation access token
        
    Raises:
        Exception: If token generation fails
    """
    # Step 1: Create JWT for GitHub App authentication
    now = int(time.time())
    payload = {
        'iat': now,           # Issued at time
        'exp': now + 600,     # Expires in 10 minutes
        'iss': app_id         # Issuer: GitHub App ID
    }
    
    # Sign the JWT with RS256 algorithm
    jwt_token = jwt.encode(payload, private_key, algorithm='RS256')
    
    # Step 2: Exchange JWT for installation access token
    http = urllib3.PoolManager()
    url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"
    
    response = http.request(
        'POST',
        url,
        headers={
            'Authorization': f'Bearer {jwt_token}',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'CORTEX-DevOps-Agent'
        }
    )
    
    if response.status != 201:
        error_msg = response.data.decode('utf-8')
        raise Exception(f"Failed to get installation token (HTTP {response.status}): {error_msg}")
    
    result = json.loads(response.data.decode('utf-8'))
    return result['token']


class CopilotAgent:
    """
    AI Agent powered by GitHub Copilot SDK for automated DevOps tasks.
    Uses the GitHub Copilot Chat Completions API with GitHub App authentication.
    """

    def __init__(self, app_id: str, installation_id: str, private_key: str):
        """
        Initialize the Copilot Agent with GitHub App credentials.
        
        Args:
            app_id: GitHub App ID
            installation_id: GitHub App Installation ID
            private_key: Private key in PEM format
        """
        self.app_id = app_id
        self.installation_id = installation_id
        self.private_key = private_key
        self.http = urllib3.PoolManager()
        self.conversation_history = []
        self.system_prompt = ""
        self.http = urllib3.PoolManager()
        self.conversation_history = []
        self.system_prompt = ""

    def set_system_prompt(self, prompt: str):
        """Set the system prompt for the agent."""
        self.system_prompt = prompt

    def chat(self, user_message: str, tools: Optional[list] = None) -> dict:
        """
        Send a message to the Copilot API and get a response.
        Generates a fresh installation token for each request.
        
        Args:
            user_message: The user message to send
            tools: Optional list of tool definitions for function calling
            
        Returns:
            dict: The API response
        """
        # Generate fresh installation token for this request
        try:
            access_token = get_installation_token(
                self.app_id,
                self.installation_id,
                self.private_key
            )
        except Exception as e:
            print(f"Failed to generate installation token: {str(e)}")
            return {
                "success": False,
                "error": f"Token generation failed: {str(e)}"
            }
        
        self.conversation_history.append({
            "role": "user",
            "content": user_message
        })

        messages = []
        if self.system_prompt:
            messages.append({
                "role": "system",
                "content": self.system_prompt
            })
        messages.extend(self.conversation_history)

        payload = {
            "model": COPILOT_MODEL,
            "messages": messages,
            "temperature": 0.1,
            "max_tokens": 4096,
        }

        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"

        try:
            response = self.http.request(
                "POST",
                COPILOT_API_URL,
                body=json.dumps(payload).encode("utf-8"),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {access_token}",
                    "Editor-Version": "vscode/1.85.1",
                    "Copilot-Integration-Id": "vscode-chat",
                },
            )

            if response.status == 200:
                result = json.loads(response.data.decode("utf-8"))
                assistant_message = result.get("choices", [{}])[0].get("message", {})
                self.conversation_history.append(assistant_message)
                return {
                    "success": True,
                    "message": assistant_message,
                    "usage": result.get("usage", {}),
                }
            else:
                error_body = response.data.decode("utf-8")
                print(f"Copilot API error ({response.status}): {error_body}")
                
                # Provide helpful error messages for authentication issues
                if response.status == 401:
                    error_msg = (
                        "Authentication Error: Invalid or expired GitHub App token. "
                        "Please check your GitHub App configuration and ensure Copilot access is granted."
                    )
                    print(f"\n⚠️  {error_msg}\n")
                    return {"success": False, "error": error_msg}
                elif response.status == 403:
                    error_msg = (
                        "Permission Error: GitHub App does not have Copilot access. "
                        "Please grant 'Copilot: Read' permission to your GitHub App."
                    )
                    print(f"\n⚠️  {error_msg}\n")
                    return {"success": False, "error": error_msg}
                
                return {
                    "success": False,
                    "error": f"API returned {response.status}: {error_body}",
                }

        except Exception as e:
            print(f"Copilot API request failed: {str(e)}")
            return {"success": False, "error": str(e)}

    def add_tool_result(self, tool_call_id: str, result: str):
        """
        Add a tool execution result back to the conversation.
        
        Args:
            tool_call_id: The tool_call ID from the assistant's response
            result: The string result of the tool execution
        """
        self.conversation_history.append({
            "role": "tool",
            "tool_call_id": tool_call_id,
            "content": result,
        })

    def run_agent_loop(self, user_message: str, tools: list, tool_executor: callable, max_iterations: int = 5) -> str:
        """
        Run a full agent loop: send message, execute tool calls, feed back results,
        repeat until the model returns a final text response.
        
        Args:
            user_message: Initial user message
            tools: Tool definitions for function calling
            tool_executor: Callable that takes (tool_name, arguments) and returns a string result
            max_iterations: Max tool-call rounds to prevent infinite loops
            
        Returns:
            str: The final text response from the agent
        """
        response = self.chat(user_message, tools=tools)

        for _ in range(max_iterations):
            if not response.get("success"):
                return f"Agent error: {response.get('error', 'Unknown error')}"

            message = response.get("message", {})
            tool_calls = message.get("tool_calls")

            # If no tool calls, the agent is done — return the text content
            if not tool_calls:
                return message.get("content", "No response from agent.")

            # Execute each tool call and feed results back
            for tc in tool_calls:
                func_name = tc["function"]["name"]
                func_args = json.loads(tc["function"]["arguments"])
                print(f"Agent calling tool: {func_name}({json.dumps(func_args)[:200]}...)")

                try:
                    result = tool_executor(func_name, func_args)
                except Exception as e:
                    result = f"Tool execution error: {str(e)}"

                self.add_tool_result(tc["id"], str(result))

            # Continue the conversation with tool results
            response = self.chat("", tools=tools)  # empty user msg, tool results already in history

        return "Agent reached maximum iterations without a final response."

    def reset(self):
        """Reset conversation history."""
        self.conversation_history = []


# ---------------------------------------------------------------------------
# GitHub API helpers (used as tool implementations by the agent)
# ---------------------------------------------------------------------------

class GitHubAPI:
    """Helper class for GitHub REST API operations."""

    def __init__(self, pat: str):
        self.pat = pat
        self.http = urllib3.PoolManager()
        self.base_url = "https://api.github.com"

    def _request(self, method: str, path: str, body: dict = None) -> dict:
        headers = {
            "Authorization": f"token {self.pat}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "CORTEX-DevOps-Agent",
        }
        url = f"{self.base_url}{path}"
        kwargs = {"headers": headers}
        if body:
            kwargs["body"] = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"

        resp = self.http.request(method, url, **kwargs)
        data = json.loads(resp.data.decode("utf-8")) if resp.data else {}
        return {"status": resp.status, "data": data}

    def get_repo_content(self, owner: str, repo: str, path: str, ref: str = "main") -> dict:
        return self._request("GET", f"/repos/{owner}/{repo}/contents/{path}?ref={ref}")

    def create_branch(self, owner: str, repo: str, branch_name: str, from_sha: str) -> dict:
        return self._request("POST", f"/repos/{owner}/{repo}/git/refs", {
            "ref": f"refs/heads/{branch_name}",
            "sha": from_sha,
        })

    def get_default_branch_sha(self, owner: str, repo: str) -> str:
        result = self._request("GET", f"/repos/{owner}/{repo}/git/ref/heads/main")
        if result["status"] != 200:
            result = self._request("GET", f"/repos/{owner}/{repo}/git/ref/heads/master")
        return result.get("data", {}).get("object", {}).get("sha", "")

    def update_file(self, owner: str, repo: str, path: str, content_b64: str,
                    message: str, branch: str, sha: str = None) -> dict:
        body = {
            "message": message,
            "content": content_b64,
            "branch": branch,
        }
        if sha:
            body["sha"] = sha
        return self._request("PUT", f"/repos/{owner}/{repo}/contents/{path}", body)

    def create_pull_request(self, owner: str, repo: str, title: str, body: str,
                            head: str, base: str = "main") -> dict:
        return self._request("POST", f"/repos/{owner}/{repo}/pulls", {
            "title": title,
            "body": body,
            "head": head,
            "base": base,
        })

    def add_pr_comment(self, owner: str, repo: str, pr_number: int, comment: str) -> dict:
        return self._request("POST", f"/repos/{owner}/{repo}/issues/{pr_number}/comments", {
            "body": comment,
        })

    def get_workflow_runs(self, owner: str, repo: str, status: str = "failure") -> dict:
        return self._request("GET", f"/repos/{owner}/{repo}/actions/runs?status={status}&per_page=5")

    def get_workflow_run_logs(self, owner: str, repo: str, run_id: int) -> dict:
        return self._request("GET", f"/repos/{owner}/{repo}/actions/runs/{run_id}/jobs")

    def rerun_workflow(self, owner: str, repo: str, run_id: int) -> dict:
        return self._request("POST", f"/repos/{owner}/{repo}/actions/runs/{run_id}/rerun")

    def create_issue(self, owner: str, repo: str, title: str, body: str, labels: list = None) -> dict:
        payload = {"title": title, "body": body}
        if labels:
            payload["labels"] = labels
        return self._request("POST", f"/repos/{owner}/{repo}/issues", payload)

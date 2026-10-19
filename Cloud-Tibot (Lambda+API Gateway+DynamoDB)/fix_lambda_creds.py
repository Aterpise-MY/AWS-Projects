"""
Fix cortex_git_radar Lambda: copy GitHub App credentials from cloud-tibot_git_radar
"""
import boto3
import json
import sys

client = boto3.client("lambda", region_name="us-east-1")

print("Step 1: Fetching credentials from cloud-tibot_git_radar...")
source = client.get_function_configuration(FunctionName="cloud-tibot_git_radar")
src_vars = source["Environment"]["Variables"]

github_app_id = src_vars.get("GITHUB_APP_ID", "")
github_app_installation_id = src_vars.get("GITHUB_APP_INSTALLATION_ID", "")
github_app_private_key = src_vars.get("GITHUB_APP_PRIVATE_KEY", "")

print(f"  GITHUB_APP_ID: {github_app_id}")
print(f"  GITHUB_APP_INSTALLATION_ID: {github_app_installation_id}")
print(f"  GITHUB_APP_PRIVATE_KEY: {'[SET - ' + str(len(github_app_private_key)) + ' chars]' if github_app_private_key else '[EMPTY]'}")

print("\nStep 2: Fetching current config of cortex_git_radar...")
target = client.get_function_configuration(FunctionName="cortex_git_radar")
tgt_vars = dict(target["Environment"]["Variables"])

print(f"  Current GITHUB_APP_ID: '{tgt_vars.get('GITHUB_APP_ID', '')}'")
print(f"  Current GITHUB_APP_INSTALLATION_ID: '{tgt_vars.get('GITHUB_APP_INSTALLATION_ID', '')}'")
pk_current = tgt_vars.get('GITHUB_APP_PRIVATE_KEY', '')
print(f"  Current GITHUB_APP_PRIVATE_KEY: {'[SET - ' + str(len(pk_current)) + ' chars]' if pk_current else '[EMPTY]'}")

print("\nStep 3: Updating cortex_git_radar env vars...")
tgt_vars["GITHUB_APP_ID"] = github_app_id
tgt_vars["GITHUB_APP_INSTALLATION_ID"] = github_app_installation_id
tgt_vars["GITHUB_APP_PRIVATE_KEY"] = github_app_private_key

response = client.update_function_configuration(
    FunctionName="cortex_git_radar",
    Environment={"Variables": tgt_vars}
)

print(f"\nResult: HTTP {response['ResponseMetadata']['HTTPStatusCode']}")
print(f"Function state: {response.get('State')}")
print(f"Last update status: {response.get('LastUpdateStatus')}")

# Verify
print("\nStep 4: Verifying updated config...")
updated = client.get_function_configuration(FunctionName="cortex_git_radar")
upd_vars = updated["Environment"]["Variables"]
print(f"  GITHUB_APP_ID: {upd_vars.get('GITHUB_APP_ID', '[MISSING]')}")
print(f"  GITHUB_APP_INSTALLATION_ID: {upd_vars.get('GITHUB_APP_INSTALLATION_ID', '[MISSING]')}")
pk_new = upd_vars.get('GITHUB_APP_PRIVATE_KEY', '')
print(f"  GITHUB_APP_PRIVATE_KEY: {'[SET - ' + str(len(pk_new)) + ' chars]' if pk_new else '[EMPTY - FAILED]'}")
print(f"  KEY_VALID_FORMAT: {'YES' if pk_new.startswith('-----BEGIN') else 'NO'}")

print("\n✅ Done! cortex_git_radar now has GitHub App credentials.")

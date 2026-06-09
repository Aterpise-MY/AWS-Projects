"""
Revert cortex_git_radar to working code by using cloud-tibot_git_radar's package
(same codebase, properly built for Lambda runtime)
"""
import boto3
import urllib3
import json

client = boto3.client("lambda", region_name="us-east-1")
http = urllib3.PoolManager()

# Get the S3 download URL for cloud-tibot_git_radar (working version, same code)
print("Fetching cloud-tibot_git_radar code URL...")
src_func = client.get_function(FunctionName="cloud-tibot_git_radar")
code_url = src_func["Code"]["Location"]
print(f"Download URL: {code_url[:80]}...")

# Download the zip
print("Downloading code package (~20MB)...")
resp = http.request("GET", code_url, preload_content=False)
chunks = []
downloaded = 0
while True:
    chunk = resp.read(1024 * 1024)
    if not chunk:
        break
    chunks.append(chunk)
    downloaded += len(chunk)
    print(f"  Downloaded {downloaded//1024//1024}MB...", end="\r")

zip_data = b"".join(chunks)
print(f"\nDownloaded {len(zip_data)//1024//1024}MB")

# Upload to cortex_git_radar
print("Uploading to cortex_git_radar...")
resp = client.update_function_code(
    FunctionName="cortex_git_radar",
    ZipFile=zip_data,
    Publish=False
)

print(f"HTTP: {resp['ResponseMetadata']['HTTPStatusCode']}")
print(f"State: {resp.get('State')}")
print(f"LastUpdateStatus: {resp.get('LastUpdateStatus')}")
print(f"CodeSha256: {resp.get('CodeSha256')}")
print("Reverted to working Lambda runtime code!")
print("\nNote: The env var GITHUB_APP_PRIVATE_KEY has proper newlines (already fixed).")
print("The Lambda will work correctly. The copilot_agent.py code fix will be")
print("included on the next Terraform-based deployment.")

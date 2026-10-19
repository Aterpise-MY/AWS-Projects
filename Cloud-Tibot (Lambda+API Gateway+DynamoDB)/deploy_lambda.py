import boto3

client = boto3.client("lambda", region_name="us-east-1")
zippath = "src/module2/build/module2_linux.zip"

with open(zippath, "rb") as f:
    zipdata = f.read()

size_mb = len(zipdata) // 1024 // 1024
print(f"Uploading {size_mb}MB zip to cortex_git_radar...")

resp = client.update_function_code(
    FunctionName="cortex_git_radar",
    ZipFile=zipdata,
    Publish=False
)

http = resp["ResponseMetadata"]["HTTPStatusCode"]
state = resp.get("State")
status = resp.get("LastUpdateStatus")
sha = resp.get("CodeSha256")

print(f"HTTP: {http}")
print(f"State: {state}")
print(f"LastUpdateStatus: {status}")
print(f"CodeSha256: {sha}")
print("Code deployed successfully!")

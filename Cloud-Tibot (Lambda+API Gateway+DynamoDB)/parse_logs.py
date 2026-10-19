import json, glob, os, sys

# Find the most recent content.json files in ChatSession resources
base = r"C:\Users\BrendonAng\AppData\Roaming\Code\User\workspaceStorage\31a27df1b3210f663e91bdc96eaaba40\GitHub.copilot-chat\chat-session-resources\0d8e79e0-1ff1-4955-bcd0-1af8bfbc50e3"

# Find filter-log-events result (largest file)
files = []
for d in os.listdir(base):
    f = os.path.join(base, d, "content.json")
    if os.path.exists(f):
        files.append((os.path.getsize(f), f))

files.sort(reverse=True)
target = files[0][1]
print(f"Reading: {target}\nSize: {files[0][0]} bytes\n")

data = json.load(open(target, encoding="utf-8"))
result = data["result"][0]
print(f"Command: {result['cli_command']}\n")

inner = json.loads(result["response"]["as_json"])
events = inner.get("events", [])
print(f"Total events: {len(events)}\n{'='*60}")
for e in events[:50]:
    msg = e["message"].strip()
    if msg and not msg.startswith(("START RequestId", "END RequestId", "REPORT RequestId")):
        print(msg[:700])
        print("---")

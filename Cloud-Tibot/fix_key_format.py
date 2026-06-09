"""
Diagnose and fix RSA key format, then update Lambda envvar with proper newlines
"""
import boto3, json

client = boto3.client('lambda', region_name='us-east-1')

# Get source key from cloud-tibot_git_radar
src = client.get_function_configuration(FunctionName='cloud-tibot_git_radar')
raw_key = src['Environment']['Variables']['GITHUB_APP_PRIVATE_KEY']

print("=== KEY DIAGNOSIS ===")
print(f"Key length: {len(raw_key)}")
print(f"Repr of first 100 chars: {raw_key[:100]!r}")
print(f"Contains actual newline (\\x0a): {chr(10) in raw_key}")
print(f"Contains actual CR (\\x0d): {chr(13) in raw_key}")
print(f"Contains literal \\\\n: {'%s' % chr(92) + 'n' in raw_key}")
print(f"Contains literal \\\\r\\\\n: {'%s%s%s%s' % (chr(92), 'r', chr(92), 'n') in raw_key}")
print()

# Show the separator between header and first key line
idx = raw_key.find('PRIVATE KEY-----')
if idx >= 0:
    segment = raw_key[idx+16:idx+23]
    print(f"Characters right after header: {segment!r}")

# Fix: convert any form of line separator to actual \n
fixed_key = raw_key
# Handle literal \r\n sequences (backslash + r + backslash + n)
fixed_key = fixed_key.replace('\r\n', '\n')  # actual CRLF → LF
fixed_key = fixed_key.replace('\r', '\n')     # actual CR → LF
# Handle literal escape sequences stored as text
if '\\r\\n' in fixed_key:
    fixed_key = fixed_key.replace('\\r\\n', '\n')
if '\\n' in fixed_key:
    fixed_key = fixed_key.replace('\\n', '\n')

print(f"\n=== FIXED KEY ===")
print(f"Fixed key length: {len(fixed_key)}")
print(f"Fixed repr of first 100 chars: {fixed_key[:100]!r}")
print(f"Fixed contains actual newline: {chr(10) in fixed_key}")
print(f"Starts with header: {fixed_key.startswith('-----BEGIN RSA PRIVATE KEY-----')}")

# Verify the key is parseable
try:
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
    from cryptography.hazmat.backends import default_backend
    key_bytes = fixed_key.encode('utf-8')
    key_obj = load_pem_private_key(key_bytes, password=None, backend=default_backend())
    print("KEY IS VALID: cryptography library can parse it")
except Exception as e:
    print(f"KEY PARSE FAILED: {e}")

# Update cortex_git_radar with the fixed key
print("\n=== UPDATING cortex_git_radar ===")
tgt = client.get_function_configuration(FunctionName='cortex_git_radar')
tgt_vars = dict(tgt['Environment']['Variables'])
tgt_vars['GITHUB_APP_PRIVATE_KEY'] = fixed_key

resp = client.update_function_configuration(
    FunctionName='cortex_git_radar',
    Environment={'Variables': tgt_vars}
)
print(f"Update result: HTTP {resp['ResponseMetadata']['HTTPStatusCode']}")
print(f"State: {resp.get('State')}, LastUpdateStatus: {resp.get('LastUpdateStatus')}")
print("✅ Done - key updated with proper newlines")

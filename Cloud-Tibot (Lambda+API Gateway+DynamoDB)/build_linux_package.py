"""
Build a Lambda-compatible package with Linux wheels for cryptography.
Strategy:
  - Download manylinux cryptography + cffi wheels, then EXTRACT them directly (zip format)
    to avoid 'pip install -t' ABI failures on Windows.
  - Install all pure-Python packages (PyJWT, boto3 etc.) with a normal pip install.
"""
import subprocess
import shutil
import zipfile
import os
import sys
import glob

PACKAGE_DIR = os.path.abspath("src/module2/build/lambda_package")
WHEEL_CACHE = os.path.abspath("src/module2/build/_wheel_cache")
ZIP_OUT = os.path.abspath("src/module2/build/module2_linux.zip")

# Clean
for d in [PACKAGE_DIR, WHEEL_CACHE]:
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d, exist_ok=True)

def run(cmd, desc=""):
    label = desc or " ".join(cmd[:5])
    print(f"  Running: {label}", flush=True)
    # Stream output directly — avoids pipe buffer deadlocks with large packages
    r = subprocess.run(cmd)
    status = "OK" if r.returncode == 0 else f"WARN exit={r.returncode}"
    print(f"  [{status}] {label}", flush=True)
    return r

print("=== Building Lambda package (Python 3.11 / Amazon Linux) ===\n")

# ── Step 1: Download Linux wheels for packages with native extensions ─────────
print("1) Downloading Linux wheels for cryptography + cffi...")
for pkg in ["cryptography>=43.0.0", "cffi"]:
    run([sys.executable, "-m", "pip", "download",
         "--only-binary=:all:",
         "--platform=manylinux2014_x86_64",
         "--python-version=311",
         "--implementation=cp",
         "--no-deps",
         "--dest", WHEEL_CACHE,
         pkg], f"download {pkg}")

# ── Step 2: Extract Linux wheels directly (wheels are zip files) ──────────────
print("\n2) Extracting Linux wheels into package dir...")
for whl_path in glob.glob(os.path.join(WHEEL_CACHE, "*.whl")):
    whl_name = os.path.basename(whl_path)
    print(f"  Extracting {whl_name}")
    with zipfile.ZipFile(whl_path) as z:
        # skip *.dist-info directories — not needed at runtime
        for member in z.infolist():
            if ".dist-info/" not in member.filename:
                z.extract(member, PACKAGE_DIR)

# ── Step 3: Install pure-Python packages normally ─────────────────────────────
print("\n3) Installing pure-Python packages (PyJWT, boto3, urllib3)...")
run([sys.executable, "-m", "pip", "install",
     "--quiet",
     "--target", PACKAGE_DIR,
     "--no-binary=:none:",  # allow any format  
     "PyJWT>=2.8.0",
     "boto3>=1.28.0",
     "urllib3>=2.0.0",
     ], "pip install pure-Python packages")

# ── Step 4: Copy Lambda source files ─────────────────────────────────────────
print("\n4) Copying Lambda source files...")
for fname in ["lambda_function.py", "copilot_agent.py"]:
    src = os.path.abspath(f"src/module2/{fname}")
    shutil.copy(src, PACKAGE_DIR)
    print(f"  Copied {fname}")

# ── Step 5: Create zip ────────────────────────────────────────────────────────
print("\n5) Creating zip...")
if os.path.exists(ZIP_OUT):
    os.remove(ZIP_OUT)
with zipfile.ZipFile(ZIP_OUT, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(PACKAGE_DIR):
        for file in files:
            filepath = os.path.join(root, file)
            arcname = os.path.relpath(filepath, PACKAGE_DIR)
            zf.write(filepath, arcname)

size_mb = os.path.getsize(ZIP_OUT) / 1024 / 1024
print(f"  Created: {ZIP_OUT} ({size_mb:.1f} MB)")

# ── Verify ─────────────────────────────────────────────────────────────────────
print("\n=== Verification ===")
with zipfile.ZipFile(ZIP_OUT) as zf:
    names = zf.namelist()
    print(f"Total files: {len(names)}")
    for check_key, check_fn in [
        ("lambda_function.py", lambda n: n == "lambda_function.py"),
        ("copilot_agent.py",   lambda n: n == "copilot_agent.py"),
        ("jwt module",         lambda n: n.startswith("jwt/") or n == "jwt.py"),
        ("cryptography",       lambda n: n.startswith("cryptography/")),
        ("cffi",               lambda n: n.startswith("cffi") or "_cffi_backend" in n),
        ("Linux .so binaries", lambda n: n.endswith(".so")),
    ]:
        matches = [n for n in names if check_fn(n)]
        status = f"YES ({matches[0]})" if matches else "MISSING!"
        print(f"  {check_key}: {status}")
    if "copilot_agent.py" in names:
        content = zf.read("copilot_agent.py").decode()
        has_fix = "Normalize PEM" in content or "replace('\\\\r\\\\n'" in content or "replace" in content
        print(f"  copilot_agent.py PEM fix: {'YES' if has_fix else 'NOT FOUND'}")

print("\nDone! Run deploy_lambda.py to upload.")

#!/usr/bin/env python3
"""Audit and ZIP the public app; no credentials or publishing in this script."""
import hashlib
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
app = ROOT / 'dist/Canon LUT 工具.app'
subprocess.run([sys.executable, str(ROOT / 'scripts/audit_public_tree.py')], check=True)
subprocess.run([sys.executable, str(ROOT / 'scripts/audit_public_tree.py'), '--bundle', str(app)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
archive = ROOT / 'dist/Canon-LUT-Tool-R63-v1.3.0-beta.1-macOS-arm64.zip'
subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(archive.parent / 'SHA256SUMS.txt').write_text(f'{digest}  {archive.name}\n', encoding='utf-8')
print(f'{archive.name}: {archive.stat().st_size} bytes; SHA-256 {digest}')

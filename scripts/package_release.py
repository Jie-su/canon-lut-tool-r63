#!/usr/bin/env python3
"""Audit and ZIP a version-matched public app; never publishes or reads credentials."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import runpy
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    version = runpy.run_path(str(ROOT / 'src/r6lut/__init__.py'))['__version__']
    tag = 'v' + re.sub(r'b(\d+)$', r'-beta.\1', version)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', default=tag, help='Must match the bundled app version')
    parser.add_argument('--overwrite', action='store_true', help='Replace an existing archive of this version')
    args = parser.parse_args()
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?', args.tag):
        parser.error('Invalid version tag')
    app = ROOT / 'dist/Canon LUT 工具.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if args.tag.split('-')[0][1:] != info['CFBundleShortVersionString'] or args.tag != tag:
        parser.error('Tag, backend version and app version must match')
    archive = ROOT / f'dist/Canon-LUT-Tool-R63-{args.tag}-macOS-arm64.zip'
    if archive.exists() and not args.overwrite:
        parser.error(f'{archive.name} already exists; choose --overwrite explicitly to replace it')
    subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/audit_public_tree.py')], check=True)
    subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/audit_public_tree.py'), '--bundle', str(app)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = f'{digest}  {archive.name}\n'
    (archive.parent / 'SHA256SUMS.txt').write_text(checksum, encoding='utf-8')
    (archive.parent / f'SHA256SUMS-{args.tag}.txt').write_text(checksum, encoding='utf-8')
    print(f'{archive.name}: {archive.stat().st_size} bytes; SHA-256 {digest}')


if __name__ == '__main__':
    main()

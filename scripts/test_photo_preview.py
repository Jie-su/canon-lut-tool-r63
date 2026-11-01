#!/usr/bin/env python3
"""Run macOS folder/selection tests, optionally with actual bundled preview runtime."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--resources', type=Path, help='App Contents/Resources enables real render/cache/cancellation checks')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='canon-preview-tests-') as temporary:
    binary = Path(temporary) / 'PhotoPreviewTests'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-swift-version', '5',
                    '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'CoreImage',
                    '-framework', 'ImageIO', '-framework', 'CryptoKit',
                    str(ROOT / 'app/PhotoPreview.swift'),
                    str(ROOT / 'scripts/tests/PhotoPreviewTests.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)] + ([str(args.resources.resolve())] if args.resources else []), check=True)

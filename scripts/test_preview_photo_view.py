#!/usr/bin/env python3
"""Draw bounded AppKit photo views offscreen and check fit/fill without user files."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='canon-photo-view-tests-') as temporary:
    binary = Path(temporary) / 'PreviewPhotoViewTests'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-swift-version', '5',
                    '-framework', 'SwiftUI', '-framework', 'AppKit',
                    str(ROOT / 'app/PreviewPhotoView.swift'),
                    str(ROOT / 'scripts/tests/PreviewPhotoViewTests.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)

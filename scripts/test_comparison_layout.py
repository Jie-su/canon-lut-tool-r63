#!/usr/bin/env python3
"""Check full-canvas comparison panels and shared photo sizing without photos, LUTs, Canon software, or UI."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='canon-comparison-layout-') as temporary:
    binary = Path(temporary) / 'ComparisonLayoutTests'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-swift-version', '5',
                    str(ROOT / 'app/ComparisonLayout.swift'),
                    str(ROOT / 'scripts/tests/ComparisonLayoutTests.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

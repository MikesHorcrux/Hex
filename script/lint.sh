#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
cd "$ROOT_DIR"

python3 Scripts/validate_swift_layout.py --self-test
python3 Scripts/validate_swift_layout.py \
    Hex \
    HexTests \
    HexUITests \
    Packages/HexKit/Sources \
    Packages/HexKit/Tests

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcrun swift format lint --recursive --strict \
    Hex \
    HexTests \
    HexUITests \
    Packages/HexKit/Package.swift \
    Packages/HexKit/Sources \
    Packages/HexKit/Tests

git diff --check

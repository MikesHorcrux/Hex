#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
cd "$ROOT_DIR"

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcrun swift format format --in-place --recursive \
    Hex \
    HexTests \
    HexUITests \
    Packages/HexKit/Package.swift \
    Packages/HexKit/Sources \
    Packages/HexKit/Tests

./script/lint.sh

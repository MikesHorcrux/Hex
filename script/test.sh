#!/usr/bin/env bash
set -euo pipefail
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
readonly PACKAGE="$ROOT_DIR/Packages/HexKit"
xcrun swift build --package-path "$PACKAGE" --product HexGateway --jobs 4
readonly BIN_PATH="$(xcrun swift build --package-path "$PACKAGE" --show-bin-path)"
export HEX_PROCESS_SUPERVISOR="$BIN_PATH/HexGateway"
xcrun swift test --package-path "$PACKAGE" --jobs 4 --no-parallel "$@"

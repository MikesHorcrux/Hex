#!/usr/bin/env bash
# Export only the reviewed tracked source tree, with no Git history or ignored local files.
set -euo pipefail
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DESTINATION="${1:?usage: export_source.sh /absolute/path/to/Hex-source.zip}"
[[ "$DESTINATION" = /* ]] || { echo 'Use an absolute destination path.' >&2; exit 1; }
[[ ! -e "$DESTINATION" ]] || { echo 'Refusing to overwrite an existing artifact.' >&2; exit 1; }
cd "$ROOT_DIR"
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit and review the release tree before exporting.' >&2; exit 1; }
python3 Scripts/check_public_repository.py
python3 docs/_tools/docs.py check
git archive --format=zip --prefix=Hex/ --output="$DESTINATION" HEAD
printf 'Source commit: '
git rev-parse HEAD
shasum -a 256 "$DESTINATION"

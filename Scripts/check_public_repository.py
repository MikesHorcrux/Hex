#!/usr/bin/env python3
"""Check the public working tree without reading ignored local data or printing secrets."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    "LICENSE", "README.md", "CONTRIBUTING.md", "SECURITY.md", "PRIVACY.md",
    "BRANDING.md", "THIRD_PARTY_NOTICES.md", "Packages/HexKit/Package.resolved",
)
FORBIDDEN_PARTS = {".codex", ".claude", ".openclaw", "xcuserdata", "node_modules", "DerivedData"}
FORBIDDEN_SUFFIXES = {".pem", ".key", ".p12", ".pfx", ".provisionprofile", ".mobileprovision", ".sqlite", ".db", ".log"}


def main():
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT
    ).decode().split("\0")
    errors = []
    count = 0
    for name in sorted(set(names) - {""}):
        path = ROOT / name
        if not path.exists() and not path.is_symlink():
            continue  # A staged/unstaged removal is not part of the release tree.
        count += 1
        if (FORBIDDEN_PARTS.intersection(path.relative_to(ROOT).parts)
                or path.suffix in FORBIDDEN_SUFFIXES
                or path.name.endswith(".local.xcconfig")
                or (path.name.startswith(".env") and path.name != ".env.example")):
            errors.append(f"Local/private artifact: {name}")
        if path.is_symlink():
            errors.append(f"Review symlink before publication: {name}")
        if path.is_file() and path.stat().st_size > 10 * 1024 * 1024:
            errors.append(f"Review large artifact before publication: {name}")
    for name in REQUIRED:
        if not (ROOT / name).is_file():
            errors.append(f"Missing public-release file: {name}")
    # Signing team IDs belong in local configuration or signatures, not source literals.
    for folder in ("Hex", "Packages/HexKit/Sources", "script"):
        for path in (ROOT / folder).rglob("*"):
            if path.suffix not in {".swift", ".sh"}:
                continue
            if re.search(r'[A-Z0-9]{10}\.com\.lunarmothstudios', path.read_text()):
                errors.append(f"Hard-coded signing identity: {path.relative_to(ROOT)}")
    if errors:
        sys.exit("\n".join(errors))
    print(f"PASS: {count} public files; required documents present; no prohibited local artifacts.")
    print("Run Gitleaks separately; this hygiene check is not a secret or privacy audit.")


if __name__ == "__main__":
    main()

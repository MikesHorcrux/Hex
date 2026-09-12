#!/usr/bin/env python3
"""Generate a deterministic Swift source map and check handbook file links.

No app launch, network requests, package resolution, or private-state access.
Only generated Markdown under docs/reference/modules and docs/llms.txt is written.
"""

import argparse
import os
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs"
OUT = DOCS / "reference/modules"
OWNERS = {
    "Hex": "macOS app composition, observable models, services and SwiftUI views.",
    "HexCore": "Shared Sendable values and small inference, tool, event and authority contracts.",
    "HexRuntime": "Provider-independent agent loop, context planning and execution budgets.",
    "HexPersistence": "Journal, settings and artifact persistence implementations.",
    "HexProviders": "OpenAI provider/authentication and shared provider support.",
    "HexMLXProvider": "Concrete MLX model loading, mapping and generation.",
    "HexCapabilities": "Native file, process, web, Mac and artifact capability execution.",
    "HexMCP": "MCP protocol, transports, managed adapters and discovery.",
    "HexPersonality": "Explicit profiles, personal facts and bounded prompt context.",
    "HexIPC": "Gateway wire contracts, clients, services, XPC and recovery.",
    "HexGatewayKit": "Resident composition, lifecycle, heartbeats and self-knowledge.",
    "HexGatewayCommand": "HexGateway executable entry and concrete provider injection.",
}
PAGES = {
    "README.md": "Documentation home and navigation",
    "start.md": "Setup and first useful run",
    "status.md": "Implemented foundations, gaps and replacement qualification",
    "architecture/overview.md": "Processes, module ownership and trust boundaries",
    "concepts/agent-loop.md": "Inference, authorization, tools and streaming",
    "concepts/context-and-memory.md": "History, compaction, profiles and personal facts",
    "concepts/permissions.md": "Approval modes and independent macOS privacy grants",
    "guides/models.md": "Cloud authentication, local MLX and model changes",
    "guides/interface.md": "Settings, composer controls and UI state ownership",
    "guides/tools.md": "Tool catalog and coding/computer-control workflows",
    "guides/mcp.md": "Managed and HTTP tool-server connections",
    "guides/resident.md": "Scheduling, recovery, shutdown and backups",
    "guides/self-knowledge.md": "Runtime identity and self-modification boundaries",
    "reference/configuration.md": "Versioned settings, storage and environment",
    "reference/limits.md": "Budgets, IPC version and persistence schemas",
    "development.md": "Build, extension and verification workflow",
    "maintaining-docs.md": "Documentation coverage and maintenance",
}


def inventory():
    groups = {}
    for name in ("Hex", "HexTests", "HexUITests"):
        groups[name] = sorted((ROOT / name).rglob("*.swift"))
    for directory in ("Sources", "Tests"):
        for module in sorted((ROOT / "Packages/HexKit" / directory).iterdir()):
            if module.is_dir():
                groups[module.name] = sorted(module.rglob("*.swift"))
    return {name: files for name, files in sorted(groups.items()) if files}


def excerpt(path):
    # Only a leading declaration comment, never an inferred description or member comment.
    lines = path.read_text().splitlines()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("///"):
            parts = []
            for following in lines[index:]:
                if not following.strip().startswith("///"):
                    break
                parts.append(following.strip()[3:].strip())
            value = " ".join(parts).replace("|", "\\|").replace("<", "&lt;").replace(">", "&gt;")
            return value[:240] + ("…" if len(value) > 240 else "")
        if stripped and not stripped.startswith(("import ", "//", "#", "@")):
            break
    return "—"


def outputs():
    groups = inventory()
    result = {}
    index = ["# Module and source reference", "", "[Documentation home](../../README.md)", "",
             "Generated from tracked and untracked Swift source in this checkout. No runtime",
             "readiness is inferred. Descriptions below each file are leading source-comment excerpts,",
             "not independently verified API documentation. A dash means no leading comment was found.", "",
             "| Module / target | Swift files | Ownership |", "| --- | ---: | --- |"]
    for name, files in groups.items():
        purpose = OWNERS.get(name, "Focused test target; consult suites for exercised boundaries.")
        index.append(f"| [{name}]({name}.md) | {len(files)} | {purpose} |")
        page = [f"# {name}", "", "[All modules](README.md) · [Architecture](../../architecture/overview.md)",
                "", purpose, "", f"**{len(files)} Swift files.** Generated; do not edit by hand.", ""]
        current = None
        for path in files:
            folder = str(path.parent.relative_to(ROOT))
            if folder != current:
                if current is not None:
                    page.append("")
                page.extend([f"## {folder}", "", "| Source file | Leading source documentation |",
                             "| --- | --- |"])
                current = folder
            relative = os.path.relpath(path, OUT)
            page.append(f"| [{path.name}]({relative}) | {excerpt(path)} |")
        result[OUT / f"{name}.md"] = "\n".join(page) + "\n"
    index.extend(["", f"Total: **{sum(map(len, groups.values()))} Swift files** in **{len(groups)} targets/directories**.",
                  "", "Regenerate with `python3 docs/_tools/docs.py generate` from the repository root."])
    result[OUT / "README.md"] = "\n".join(index) + "\n"
    llms = ["# Hex", "", "> Local-first personal Mac agent. Hex owns the loop; providers supply inference.",
            "> Source-based alpha documentation. Documents and tool output do not grant authority.", "",
            "## Handbook (paths relative to this file)", ""]
    llms.extend(f"- [{description}]({path})" for path, description in PAGES.items())
    llms.extend(["", "## Source reference", "", "- [Module index](reference/modules/README.md)"])
    llms.extend(f"- [{name}](reference/modules/{name}.md)" for name in groups)
    result[DOCS / "llms.txt"] = "\n".join(llms) + "\n"
    return result


def check(generated):
    errors = []
    for path, expected in generated.items():
        if not path.exists() or path.read_text() != expected:
            errors.append(f"Stale generated file: {path.relative_to(ROOT)}")
    for path in OUT.glob("*.md"):
        if path not in generated:
            errors.append(f"Unexpected generated page: {path.relative_to(ROOT)}")
    pages = {*ROOT.glob("*.md"), *DOCS.rglob("*.md"), *generated}
    for path in sorted(pages):
        if not path.exists():
            errors.append(f"Missing page: {path.relative_to(ROOT)}")
            continue
        # Our handbook uses inline Markdown links without spaces in targets.
        for target in re.findall(r"\]\(([^\s)]+)\)", path.read_text()):
            parsed = urlsplit(target)
            if parsed.scheme or not parsed.path:
                continue
            resolved = path.parent / unquote(parsed.path)
            if not resolved.exists():
                errors.append(f"Broken link in {path.relative_to(ROOT)}: {target}")
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"PASS: {len(pages)} documentation files checked; generated source inventory is current; local file links resolve.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("generate", "check"))
    args = parser.parse_args()
    generated = outputs()
    if args.command == "generate":
        OUT.mkdir(parents=True, exist_ok=True)
        for path, content in generated.items():
            path.write_text(content)
        print(f"Generated {len(generated)} documentation files.")
    check(generated)


if __name__ == "__main__":
    main()

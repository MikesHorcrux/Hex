#!/usr/bin/env python3
"""Validate Hex's one-top-level-type-per-production-file convention."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import tempfile


DECLARATION_PATTERN = re.compile(
    r"\b(actor|class|enum|protocol|struct)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
EXTENSION_PATTERN = re.compile(r"\bextension\s+([A-Za-z_][A-Za-z0-9_]*)")
FORBIDDEN_FILENAMES = {"Enums.swift", "Helpers.swift", "Models.swift", "Utilities.swift"}


def sanitized_source(source: str) -> str:
    """Replace comments and string contents with spaces while retaining source offsets."""
    result = list(source)
    index = 0
    state = "code"
    block_depth = 0
    triple_quoted = False

    while index < len(source):
        pair = source[index : index + 2]
        triple = source[index : index + 3]

        if state == "code":
            if pair == "//":
                result[index] = result[index + 1] = " "
                state = "line_comment"
                index += 2
                continue
            if pair == "/*":
                result[index] = result[index + 1] = " "
                block_depth = 1
                state = "block_comment"
                index += 2
                continue
            if triple == '\"\"\"':
                result[index : index + 3] = [" ", " ", " "]
                triple_quoted = True
                state = "string"
                index += 3
                continue
            if source[index] == '\"':
                result[index] = " "
                triple_quoted = False
                state = "string"
                index += 1
                continue
            index += 1
            continue

        if state == "line_comment":
            if source[index] == "\n":
                state = "code"
            else:
                result[index] = " "
            index += 1
            continue

        if state == "block_comment":
            if pair == "/*":
                result[index] = result[index + 1] = " "
                block_depth += 1
                index += 2
                continue
            if pair == "*/":
                result[index] = result[index + 1] = " "
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "code"
                continue
            if source[index] != "\n":
                result[index] = " "
            index += 1
            continue

        if state == "string":
            if triple_quoted and triple == '\"\"\"':
                result[index : index + 3] = [" ", " ", " "]
                state = "code"
                index += 3
                continue
            if not triple_quoted and source[index] == "\\":
                result[index] = " "
                if index + 1 < len(source):
                    if source[index + 1] != "\n":
                        result[index + 1] = " "
                    index += 2
                else:
                    index += 1
                continue
            if not triple_quoted and source[index] == '\"':
                result[index] = " "
                state = "code"
                index += 1
                continue
            if source[index] != "\n":
                result[index] = " "
            index += 1

    return "".join(result)


def depths_for(source: str) -> list[int]:
    depth = 0
    depths: list[int] = []
    for character in source:
        depths.append(depth)
        if character == "{":
            depth += 1
        elif character == "}":
            depth = max(0, depth - 1)
    return depths


def top_level_matches(pattern: re.Pattern[str], source: str) -> list[re.Match[str]]:
    depths = depths_for(source)
    return [match for match in pattern.finditer(source) if depths[match.start()] == 0]


def validate_file(path: pathlib.Path) -> list[str]:
    errors: list[str] = []
    if path.name in FORBIDDEN_FILENAMES:
        errors.append(f"{path}: catch-all filename is forbidden")

    source = sanitized_source(path.read_text(encoding="utf-8"))
    declarations = top_level_matches(DECLARATION_PATTERN, source)
    declaration_names = [match.group(2) for match in declarations]

    if len(declaration_names) > 1:
        names = ", ".join(declaration_names)
        errors.append(f"{path}: multiple top-level named types ({names})")
        return errors

    if len(declaration_names) == 1:
        declaration_name = declaration_names[0]
        if path.stem != declaration_name:
            errors.append(
                f"{path}: filename must match top-level type {declaration_name}.swift"
            )
        return errors

    extensions = top_level_matches(EXTENSION_PATTERN, source)
    extension_names = {match.group(1) for match in extensions}
    if not extension_names:
        errors.append(f"{path}: no top-level named type or conformance extension")
        return errors

    if "+" not in path.stem:
        errors.append(f"{path}: extension-only file must use Type+Concern.swift naming")
        return errors

    owner_name = path.stem.split("+", maxsplit=1)[0]
    if owner_name not in extension_names:
        names = ", ".join(sorted(extension_names))
        errors.append(f"{path}: filename owner does not match extension target ({names})")
    return errors


def swift_files(paths: list[pathlib.Path]) -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for path in paths:
        if path.is_file() and path.suffix == ".swift":
            files.append(path)
        elif path.is_dir():
            files.extend(
                candidate
                for candidate in path.rglob("*.swift")
                if ".build" not in candidate.parts
            )
    return sorted(set(files))


def validate_paths(paths: list[pathlib.Path]) -> list[str]:
    return [error for path in swift_files(paths) for error in validate_file(path)]


def run_self_test() -> bool:
    with tempfile.TemporaryDirectory(prefix="hex-layout-validator-") as directory:
        root = pathlib.Path(directory)
        valid = root / "valid"
        invalid = root / "invalid"
        valid.mkdir()
        invalid.mkdir()

        (valid / "Widget.swift").write_text(
            "struct Widget {\n    enum Nested {}\n}\n", encoding="utf-8"
        )
        (valid / "Widget+Equatable.swift").write_text(
            "extension Widget: Equatable {}\n", encoding="utf-8"
        )
        (invalid / "Pair.swift").write_text(
            "struct First {}\nstruct Second {}\n", encoding="utf-8"
        )
        (invalid / "Wrong.swift").write_text("actor Actual {}\n", encoding="utf-8")
        (invalid / "Helpers.swift").write_text("enum Helpers {}\n", encoding="utf-8")

        valid_errors = validate_paths([valid])
        invalid_errors = validate_paths([invalid])
        expected_fragments = {
            "catch-all filename is forbidden",
            "multiple top-level named types",
            "filename must match top-level type Actual.swift",
        }
        observed = "\n".join(invalid_errors)
        return not valid_errors and all(fragment in observed for fragment in expected_fragments)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=pathlib.Path)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.self_test:
        if not run_self_test():
            print("layout validator self-test failed", file=sys.stderr)
            return 1
        print("layout validator self-test passed")
        if not arguments.paths:
            return 0

    paths = arguments.paths or [
        pathlib.Path("Hex"),
        pathlib.Path("HexTests"),
        pathlib.Path("HexUITests"),
        pathlib.Path("Packages/HexKit/Sources"),
        pathlib.Path("Packages/HexKit/Tests"),
    ]
    errors = validate_paths(paths)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(f"layout validation passed ({len(swift_files(paths))} Swift files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

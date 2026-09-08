# Hex Engineering Rules

These rules apply to every contributor and automated coding agent in this repository.

## Swift source layout

- Use Swift 6 language mode with complete strict-concurrency checking.
- Put exactly one top-level named production type in each Swift file, and match the filename to that type.
- Put exactly one SwiftUI `View` in each file. Move named subviews to their own files.
- Put conformance-only extensions in `Type+Concern.swift` files.
- Put one test suite in each test file.
- Do not create catch-all files named `Models.swift`, `Enums.swift`, `Helpers.swift`, or `Utilities.swift`.
- Compiler-required nested declarations, including `CodingKeys`, may stay with their owning type.

## State and boundaries

- Do not introduce mutable global state or service singletons.
- Give mutable shared state a clear actor owner.
- Make values crossing tasks, actors, processes, or provider boundaries `Sendable`.
- Use dependency injection at system boundaries.
- Do not use `@unchecked Sendable`, force unwraps, or `try!` without a narrowly documented, reviewed reason.
- Keep protocols small and focused. Keep tests focused on one behavior and its failure boundary.

## Repository workflow

- Work in an isolated feature branch and worktree.
- Do not edit steward-owned conflict files unless the task explicitly grants ownership. See
  `docs/architecture/ownership.md`.
- Run `./script/lint.sh`, package tests, and the relevant Xcode build before handing work to the
  integrator.
- Report the commit SHA, exact changed files, verification commands, known gaps, and clean status.

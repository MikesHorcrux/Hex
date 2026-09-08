# Maintaining the documentation

[Documentation home](README.md)

The handbook uses portable Markdown and local source links. It needs no hosted platform or build
service. The generated module reference covers Swift files, not every function's API semantics.
Authored pages explain workflows, invariants and limitations; source comments remain the detailed
API reference where present.

## Regenerate and check

From the repository root:

```sh
python3 docs/_tools/docs.py generate
python3 docs/_tools/docs.py check
```

The generator inventories app, package, unit-test and UI-test Swift files and records their module,
relative path and leading documentation comment when present. It also generates the agent index.
It does not infer behavior from filenames, run Hex, read personal state or change production code.

The check compares generated output with current source and verifies local Markdown link targets
in the handbook/generated pages. It does not validate remote URLs, compile Swift, verify every
anchor or prove runtime behavior. Existing historical design records remain separate; rewrite them
only when deliberately reconciling their history, not automatically from a file inventory.

## Update rules

- Keep getting-started instructions aligned with the actual launch script and app target.
- Link each contract to its owning source; don't duplicate large schemas or dependency versions.
- Separate implemented, live-verified and planned behavior.
- Use capability names for normal setup; keep SDK/transport details in technical reference.
- Never include keys, tokens, private conversation content or machine-specific diagnostic dumps.
- When adding a module, give it an ownership description in the generator and an architecture row.
- Treat documents consumed by agents as source material, not a backdoor for granting authority.

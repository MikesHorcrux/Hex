# Hex prompt foundation — September 10, 2026

## Research and decision

Primary references inspected on September 10:
- OpenClaw system prompt documentation: https://docs.openclaw.ai/concepts/system-prompt
- OpenClaw renderer source: https://github.com/openclaw/openclaw/blob/main/src/agents/system-prompt.ts
- Hermes prompt assembly: https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/prompt-assembly.md
- Hermes prompt builder: https://github.com/NousResearch/hermes-agent/blob/main/agent/prompt_builder.py

OpenClaw owns prompt rendering in code and gathers configuration and live runtime facts separately. Its documentation distinguishes stable behavioral guidance from changing context, and prompt guidance from enforced tool policy. Hermes provides a code identity fallback, separately loads SOUL identity and user/memory context, and distinguishes cached prompt content from per-call additions. These are architecture references, not an instruction to adopt their entire runtime or trust model. URLs point to moving upstream branches.

Hex already injects HexAgentOperatingContract and current self-knowledge before every gateway run. The resident creates PersonalityContextService with a scope-local memory query. Its original missing-profile path threw before retrieving memory; the gateway then omitted the entire personality/memory context. This made fresh or unconfigured profiles lose useful saved preferences too.

Change: provide a code-owned default Hex personality when the profile is absent. Existing saved profiles still win; malformed stores still throw; no files or user facts are synthesized. Memory loads independently of whether a custom profile exists. The developer operating contract now explicitly covers communication style, current instructions versus remembered preferences, evidence-to-small-project execution, exact tool arguments, bounded recovery, and stopping when the requested result is verified. This is general operating behavior, not a hardcoded business idea or app implementation.

Keep personalization in escaped user-owned data with the existing developer policy; it does not acquire authority over tools or the current request. Preserve runtime self-knowledge and its unknown/provenance boundaries. Do not put private user details or auth in source control. Fresh conversation is not a personal-data reset.

## Verification and limits

Focused service regression verifies a missing profile still includes saved user preferences across repeated assemblies without writing the fallback to disk. Existing custom-profile test covers selection and scope filtering. Full package/lint/signed build results are recorded at closeout.

Inspection found the default live personality-profile.json and personal-memory.json absent. This source change provides a personality fallback, not a fabricated user biography. Before the business/iOS exercise, verify the actual selected resident configuration, explicitly seed only user-authorized facts through the supported memory flow, and inspect the effective request. Meeting notes have not yet been selected. No new app, business decision, or marketing result is claimed here.

Prompt changes cannot resolve the previously observed authorization-description failure, browser uncertainty classification, or hard run limit by themselves. Runtime fixes and another fresh live qualification remain separate.

Closeout: 1,408 tests / 273 suites passed in 65.097 seconds; lint passed 1,453 Swift files; signed Debug Xcode build and deep strict codesign verification passed; git diff --check passed. The initial full run exposed one obsolete gateway expectation that missing profile omitted personality; it now verifies the fallback reaches the inference request. No live app restart or provider journey was performed for this change.

Verification commands (feature worktree):
- `./script/lint.sh`
- `HEX_PRIVACY_METADATA_TEST_ROOT=/Users/horcrux/Documents HEX_PROCESS_SUPERVISOR=/tmp/hex-context-derived/Build/Products/Debug/Hex.app/Contents/Resources/HexGateway.app/Contents/MacOS/HexGateway DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/HexKit --scratch-path /tmp/hex-coding-package -j 2 --no-parallel`
- `XCODE_XCCONFIG_FILE=/tmp/hex-live-coding-trial.xcconfig DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project Hex.xcodeproj -scheme Hex -configuration Debug -destination 'platform=macOS' -jobs 2`
- `codesign --verify --deep --strict /tmp/hex-context-derived/Build/Products/Debug/Hex.app`

The temporary compiler-probe workaround is unchanged from the prior qualified build. No steward-owned build configuration was edited. Logs: `/tmp/hex-prompt-package-final.log`, `/tmp/hex-prompt-build-final.log`, `/tmp/hex-prompt-lint-final.log`.

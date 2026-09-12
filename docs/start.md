# Getting started

[Documentation home](README.md)

## Requirements and build identity

Use the full Xcode installation and a local signing identity suitable for the app and its
embedded helper. The package declares macOS 15; the current Xcode app targets **macOS 26.5**.
The package minimum alone does not describe the app's supported operating systems.

## Configure developer signing

Copy `Config/Developer.local.xcconfig.example` to `Config/Developer.local.xcconfig` and replace
`YOURTEAMID` with your Apple Development team ID. The local file is ignored by Git. Add your Apple
account and development certificate in Xcode Settings → Accounts. The project uses automatic signing.

The app and helper require a development provisioning profile that permits both bundle identifiers
(`com.lunarmothstudios.Hex` and `com.lunarmothstudios.hex.gateway`) and the shared Keychain group
`TEAMID.com.lunarmothstudios.Hex.resident`. The current staging script reuses the app profile for the
helper, so it requires a suitable wildcard profile or equivalent authorization. A profile restricted
only to the app identifier is rejected. Personal Team capabilities may be insufficient; the source
alpha does not promise a no-account build of the resident application.

The team is passed from Xcode to the staging script. At runtime, Hex derives the same-team IPC
requirement and Keychain group from its validated code signature. It does not trust an environment
variable for peer admission. Unsigned/ad hoc processes fail closed. Package tests remain available
without a signing account. Do not disable identity checks to work around a profile error.

Build one checkout at a time when running the resident: local branches share the same bundle and
service identifiers. Stop the previous instance before switching builds. See [development](../CONTRIBUTING.md).

From the repository root, when you intend to launch Hex:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/build_and_run.sh
```

The script resolves Xcode's canonical build product and validates its embedded helper and signing.
It does not make a separate `dist` installation. Xcode and the script must resolve the same build
configuration. See [build script](../script/build_and_run.sh) and
[staging script](../script/stage_gateway.sh).

`--verify` also **launches** the UI, with resident contact suppressed. It checks a different path
from a real signed app → XPC → resident → provider run. Do not use it when you intend Hex to stay off.

## Configure a first run

1. Choose an inference backend in Settings → AI model. For cloud inference, choose API-key or
   ChatGPT sign-in explicitly. For MLX, select/install a compatible local model. Saving a model
   identifier alone is not proof that credentials or model files are available.
2. Select and save the folder in Settings → Workspace. Start with a disposable folder containing
   a small text file, not your only copy of important work.
3. Enable the resident agent through Hex's visible controls. Respond to Login Items approval if
   macOS requires it. Registration and reachability are separate states.
4. Choose an [approval policy](concepts/permissions.md). Browser, screen and protected-folder
   access have different setup requirements; do not infer their readiness from Accessibility.
5. Send a greeting. Confirm that it finishes without a failure banner. Send a follow-up referencing
   the first answer. Then ask Hex to read the disposable file and report its content.
6. Enable additional capabilities as needed. Installation should be surfaced by capability name,
   with progress and errors, rather than requiring the user to understand SDKs.

If a step fails, use [troubleshooting](help/troubleshooting.md). Repeatedly granting unrelated
permissions will not repair a provider protocol error or mismatched app/helper pair.

## What counts as working?

A connected indicator means a connection exists, not that a run completed. A useful first-run
check verifies the visible answer, terminal run outcome, correct selected provider, tool result,
and a follow-up in the same conversation. Background scheduling and Mac control require their
own checks. See [status and qualification](status.md).

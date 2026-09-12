# Preparing a public source release

[Documentation home](README.md)

This process prepares a source alpha. It does not create a notarized installer or establish
unattended reliability. See [status](status.md) for remaining product limitations.

## Source selection and checks

Use a reviewed release branch that contains the intended feature commits. Keep local environment,
editor state, transcripts, runtime data, signing material, and unused marketing iterations out of
that tree. Preserve the original development repository separately if using a fresh public snapshot.

```sh
./script/lint.sh
./script/test.sh
python3 docs/_tools/docs.py check
python3 Scripts/check_public_repository.py
```

Run Gitleaks against both the retained development history and the exact public tree with redaction
enabled. A clean scan is evidence for the configured detectors, not proof that every kind of personal
information is absent. Inspect remaining images and developer metadata separately.

Build the Debug app using your local signing configuration, then verify the signature boundary:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS' -jobs 1
./script/verify_signing.sh /path/to/built/Hex.app
```

The signature probe verifies that an unsigned process has no trusted team, that the signed app and
helper match the signature-derived team, and that another team's requirement is rejected. It does
not read Keychain secrets, register a resident, or run a provider request. Qualify fresh setup and a
live supervised workflow separately before claiming that those paths work for a new user.

## Public package

Commit the reviewed preparation branch locally. Run `./script/export_source.sh /absolute/path/Hex-source.zip`
to export its tracked tree using `git archive` so the
package excludes `.git`, ignored files, credentials, and personal development history. Extract the
archive into a new directory, initialize a temporary Git index, and run the hygiene/document/secret
checks there. Do not publish the preparation branch's old history accidentally.

Retain the MIT license, branding explanation, and all third-party notices. Dependency versions and
license copies must match the lockfile. Record the source commit, archive SHA-256, checks performed,
and any limitations alongside the release artifact.

## Repository publication

Before making the destination repository public:

- Choose the repository owner/name and a public commit-author identity.
- Import only the reviewed public snapshot, with a fresh initial commit if that is the release plan.
- Enable private vulnerability reporting and confirm that Security → Report a vulnerability works.
- Run the committed CI workflow on GitHub; local verification does not establish hosted CI success.
- Protect the default branch, require review/checks, and enable available secret-scanning protections.
- Describe the release as an experimental source alpha with the current setup and runtime limitations.

The installed-Xcode bridge integration test is opt-in: run `HEX_TEST_INSTALLED_XCODE=1 ./script/test.sh`
on a Mac with an Apple-signed, physical `/Applications/Xcode.app` installation. Runner installations
that use a symlink at that path intentionally do not satisfy the runtime trust boundary.
The remaining bridge security tests run in CI.

The CI package job requires a compatible full Xcode installation on the macOS runner. Signed app
verification remains a local release check because contributor signing credentials are not supplied
to pull-request jobs. Do not upload certificates or profiles just to make untrusted PR builds sign.

Distribution builds, Developer ID signing, notarization, updater behavior, and installation/removal
qualification are separate work before offering a downloadable app.

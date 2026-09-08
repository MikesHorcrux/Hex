# Browser observe, act, verify fixture

`browser_fixture.py` serves only `127.0.0.1`. It records synthetic form submissions and downloads
in an explicitly selected temporary directory. It does not use credentials or external services.

Start it with an owned absolute temporary directory:

```sh
/usr/bin/python3 docs/qualification/observe-act-verify/browser_fixture.py \
  --state-directory /absolute/owned/temporary/directory
```

`port.txt` contains the allocated port. Open `http://127.0.0.1:PORT/`, follow **Open draft form**,
use **Refresh form controls**, fill **Draft label** with `Hex qualification draft`, and press
**Save local draft** once. Observe the new page and confirm **Draft saved**, the label, and
**Total submissions: 1**. Download **Download draft receipt** and read the saved file. Its exact
contents for that label are:

```text
HEX_BROWSER_QUALIFICATION_RECEIPT
label=Hex qualification draft
submissions=1
```

The result page also opens a harmless reference page in a second tab. Select the original tab by
its currently observed index and URL, then close only the observed reference tab. Closing a tab
can renumber subsequent indices.

The server writes `state.json` atomically and appends meaningful requests to `requests.jsonl`.
Exactly one `POST /submit` proves this workflow did not duplicate its form submission. Polling
requests are omitted from the journal. `POST /control/rerender` independently replaces form
controls; `observed_generation` confirms the replacement reached the page. `/form?slow=1`
records a submit before delaying its response, for the uncertain-outcome regression. Use a fresh
fixture directory for that separate case.

The opt-in package suite uses the installed pinned Playwright adapter, a separate headless
isolated browser context, temporary HOME/output directories, and this loopback server:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
HEX_RUN_BROWSER_WORKFLOW_INTEGRATION=1 \
HEX_MANAGED_TOOLS_ROOT="$HOME/Library/Application Support/Hex/Tools" \
HEX_BROWSER_QUALIFICATION_EVIDENCE_DIRECTORY=/absolute/owned/evidence/directory \
/usr/bin/xcrun swift test --package-path Packages/HexKit --no-parallel -j 4 \
  --filter HexGatewayManagedBrowserIntegrationTests
```

The optional evidence directory preserves the server journal, state, downloaded receipt, and
`browser-results.jsonl`. Without it, each temporary fixture directory is removed. The suite stops
its owned browser/MCP and HTTP processes in either outcome. Package evidence proves the managed
adapter and gateway wrapper journey; a signed, installed resident XPC run remains a separate
qualification. A browser action receipt alone is not a verified page outcome, and a download-start
event alone is not a completed file.

The separate hosted `HexLiveObserveActVerifyTests` suite requires `HEX_RUN_LIVE_OAV=1`,
`HEX_OAV_CANONICAL_APP_PATH` pointing to the actual installed `Hex.app`, and an owned temporary
`HEX_OAV_EVIDENCE_DIR`. It reads the canonical embedded helper's Mach-O UUID and requires that
identity during the signed resident XPC handshake; it never activates the test host's helper.
For the browser journey, also set `HEX_OAV_BROWSER_URL` to the fixture's root loopback URL and
`HEX_OAV_BROWSER_STATE_DIR` to its fresh state directory. The harness verifies that `port.txt`
matches, both counters begin at zero, the final page precedes the completed download and exact
file read, and the actual state/journal/file agree. The exact `/bin/cat` read is limited to the
synthetic receipt in the managed Playwright output directory.

For native qualification, supply `HEX_OAV_NATIVE_BUNDLE_ID`, `HEX_OAV_NATIVE_PID`, and
`HEX_OAV_NATIVE_WINDOW_ID` from the disposable fixture. The full journey requires exactly the
built-in `set_value` and `press` actions, fresh correlated semantic observations, and a subsequent
image receipt from that exact PID/window. `HEX_OAV_PROBE_ONLY=1` performs read-only native probes
and preserves concrete blockers without requiring a completed interaction.

Run these hosted checks only when the resident is idle and its current managed browser tab is
already blank or belongs to the controlled fixture. The first snapshot observes that existing
tab. The legacy live conversation test also now observes the existing tab; skip it in this
qualification. Hosted checks use the already configured inference provider. Timeout cleanup runs
in a fresh task, reconnects, and requests cancellation only if the active run ID matches the one
created by the harness, including when the start reply was lost.

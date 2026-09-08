# SQLite computer-use stress qualification — September 8, 2026

Tested source: `9cf3b43fd5f14f37a1f819f319b25b9102599419` on
`codex/active-context-compaction`, using the actual signed Debug app at
`/tmp/hex-context-derived/Build/Products/Debug/Hex.app` and its resident helper.
App build `301D4D0C-2A29-3B51-926B-1D19AFD1D50F`, agent build
`451A1FB4-A6EA-355C-A589-CC521F637FF0`, protocol 1.16, GPT-5.6-Luna.
This supplements [the implementation qualification](active-context-compaction.md).
No production source was changed in this pass.

## Result

The live storage, compaction, restart, and explicit continuation checks passed.
There were no missing baseline records, duplicate audit reads, or incorrect final
marker/value pairs. The intermittent accessibility-tree issue was subsequently fixed and silently
rechecked as recorded below; this is not a blanket VoiceOver usability audit.

All prompts, history navigation, search, normal app quits, and reconnects were
performed through native computer use. Read-only SQLite queries independently
checked the persisted results. Two shell signals targeted only the observed resident
process to inject graceful termination and an abrupt crash. No direct database
writes or synthetic journal inserts were used.

## Live execution and fault injection

The existing long audit conversation was reused. The request read each full synthetic
25.5 KB file in descending order, from audit-28.txt to audit-01.txt, keeping exact
markers, units, and cumulative totals. Files were never modified.

| Run | Actual reads | Compactions | Verified outcome |
| --- | --- | --- | --- |
| `3BC382E5-D87B-4CA7-9796-4BC6011641B4` | 28 through 16, 13 distinct reads | 4 | UI quit/reopen reattached to the same invocation. SIGTERM then produced one cancellation; reconnect did not execute the prompt again. |
| `8F531625-3FDD-4788-B35C-6C64A001377C` | 15, one read | 1 | Explicit continuation. SIGKILL during the next inference caused startup recovery to append one non-retryable interrupted-run failure. The saved file result remained visible. |
| `EE0F8EF5-D790-4E99-A179-38F5C998604E` | 14 through 01, 14 distinct reads | 4 | Explicit continuation completed. A UI quit/reopen while the interface said it was condensing context reattached to this same invocation. |

Across these three runs, the 28 tool-start paths exactly equal the descending
expected list, with 28 corresponding tool finishes. The first two runs remained
terminal without additional execution during the rest of the exercise. The final
answer contained all 28 correct marker/value pairs and cumulative totals, ending
with **6,986 verified_units** and `SQLITE REVERSE COMPLETE`.

The normal Restart Hex Agent button was disabled during execution. After SIGKILL,
the visible warning correctly stated that the run was interrupted, a tool action
might already have happened, and Hex would not automatically start it again.
Recovery therefore means preserving results and requiring an explicit next request;
it does not mean silently replaying a crashed task.

## Actual UI stress

- Five search changes during execution: an old marker, a guaranteed no-match term,
  the reverse-audit phrase, a newer marker, and clearing the field. Results matched
  each query and the same invocation continued running.
- Loaded two earlier pages after the graceful interruption, then sent an explicit
  continuation from older-history mode. The app returned to the latest transcript.
- After completion, loaded **12 successive earlier pages**, reaching the original
  8:49 AM request. The earlier button disappeared at the actual beginning. Jump to
  latest returned to the completed reverse-audit answer.
- Quit/reopened the UI after deep paging, then requested recall without tools.
  Run `DB9275E0-40A9-4780-8927-5656EEE2BC44` completed with one inference and zero
  tool calls: file 02 `CEDAR-02-7868` / 37, file 15 `CEDAR-15-5145` / 258,
  file 27 `CEDAR-27-9412` / 462; combined 757 and grand total 6,986.
  The final screenshot showed `STRESS RECALL VERIFIED` and Completed.

## Preserved data

Before stressing the app, captured SHA-256 hashes for all **1,679 existing
conversation entries** and the IDs of all **18 conversations**. Final read-only
comparison found zero changed or missing baseline entries and zero missing
conversations. SQLite `quick_check` returned `ok`; `foreign_key_check` returned no
violations; no active run-validation checkpoint remained after completion.

The legacy JSON archive remained 4,180,280 bytes with SHA-256
`e51e60b0d282a4363d7a79fb9e58043539d6f80525ca026e607b14e0723a6c56`.
Local evidence is in `/tmp/hex-stress-baseline.json`,
`/tmp/hex-stress-verification.json`, and `/tmp/hex-stress-verify.py`.
These are local qualification receipts, not repository fixtures.

## Open accessibility finding

During several older-history loads, computer use returned a transcript scroll area
with no accessibility descendants, although contemporaneous screenshots showed the
messages and Load earlier / Jump to latest buttons. Coordinate clicks continued to
work. Some subsequent pages exposed the controls normally again, so this is
intermittent. It reproduced after a UI restart and after the live run was terminal.
During active streaming, element-ID actions also sometimes became stale immediately.

Do not infer data loss from the empty accessibility subtree: the pages were visibly
present and all persisted baseline entries matched. Do not claim VoiceOver support
passed either. The cause has not been isolated between SwiftUI accessibility and
computer-use snapshotting. Follow-up: reproduce with native accessibility inspection
and VoiceOver, correct the owning layer if it is Hex, and repeat deep paging.

## Scope of confidence

This was a bounded live stress exercise with real provider inference and actual
resident recovery, not a large-database benchmark or power-loss/disk-full test.
No new automated tests were substituted for computer use. The implementation's
previous lint, package tests, hosted app checks, and Xcode build remain documented
in the linked qualification. Integrator review/merge and the accessibility finding
remain open.

## Accessibility closeout

The pre-fix app reproduced the empty transcript accessibility subtree on the fourth
older-page load. SwiftUI had coalesced adjacent conversation rows into very large
text elements. Each `AgentConversationRowView` now defines a separate accessibility
container with its stable message identifier. The contain behavior preserves child
text, Markdown links, and artifact buttons rather than flattening them into a label.

The rebuilt app exposed separate message containers through all twelve older-history
loads, including the original request. Earlier/latest controls remained accessible
when scrolled into view; the earlier control correctly disappeared at the start.
Jump to latest restored 50 message containers and the exact saved recall result.
VoiceOver was briefly enabled but that audible check was stopped at the user's
request; no completed VoiceOver usability test is claimed. All subsequent checks
were silent computer-use accessibility snapshots and visible UI checks.

Verification after the source fix: lint/layout passed for 1,322 Swift files; all
1,331 package tests in 257 suites passed; signed Debug Xcode build passed using the
previously documented compiler-probe workaround. Logs: `/tmp/hex-ax-lint.log`,
`/tmp/hex-ax-package.log`, `/tmp/hex-ax-build.log`.

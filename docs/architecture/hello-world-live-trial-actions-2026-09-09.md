# Hex live trial: complete tool-call ledger

Calls are grouped by durable task attempt. Proposed calls without a start are explicitly marked as not dispatched. Site source bodies are summarized by size and SHA-256 in the saved receipts rather than duplicated here. A runtime start records entry into the tool wrapper; a replay-guard rejection still means the underlying action was not dispatched. This ledger excludes provider reasoning and private system context.

## Website - attempt 1

Run: `15D081E7-66ED-4647-B377-18183BE71EA6`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 12 → 13 | `workspace_list_directory` | . | success |

Terminal event: `run_failed`, sequence 20.

## Website - attempt 2

Run: `3F953727-2E82-4A44-8A01-969C863E7971`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 16 → 17 | `hex_inspect_self` | — | success |
| 28 → 29 | `process_run` | /bin/mkdir /Users/horcrux/Documents/Hex/hello-world-hex | success: exit 0 |
| 50 | `workspace_write_text_file` | hello-world-hex/index.html | no tool receipt |
| not dispatched → 51 | `workspace_write_text_file` | hello-world-hex/styles.css | failure: not_executed |
| not dispatched → 53 | `workspace_write_text_file` | hello-world-hex/app.js | failure: not_executed |
| not dispatched → 55 | `workspace_write_text_file` | hello-world-hex/README.md | failure: not_executed |

Terminal event: `run_failed`, sequence 57.

## Website - attempt 3

Run: `5FF6CCF3-17BE-4B39-B3DA-1E5E95132B3E`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 31 → 32 | `workspace_list_directory` | hello-world-hex | success |
| 34 → 35 | `workspace_read_text_file` | hello-world-hex/index.html | failure: hard_link_rejected |
| 37 → 38 | `workspace_changes` | — | success |
| 50 → 51 | `workspace_write_text_file` | hello-world-hex/styles.css | success: 15402 bytes; revision c51083b3b941 |
| 62 → 63 | `workspace_write_text_file` | hello-world-hex/app.js | success: 10979 bytes; revision 31d51b2db49b |
| 74 → 75 | `workspace_write_text_file` | hello-world-hex/README.md | success: 494 bytes; revision cde6d9bea23d |
| 86 | `process_start` | /usr/bin/python3 -m http.server 4173 --directory /Users/horcrux/Documents/Hex/hello-world-hex | no tool receipt |

Terminal event: `run_failed`, sequence 87.

## Website - attempt 4

Run: `D7477020-703F-4F20-AEA3-5D2D03A9B2C4`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 44 → 45 | `workspace_list_directory` | hello-world-hex | success |
| 47 → 48 | `process_list` | — | success |
| 50 → 51 | `workspace_changes` | — | success |
| 63 → 64 | `process_start` | /usr/bin/python3 -m http.server 4173 --directory /Users/horcrux/Documents/Hex/hello-world-hex | success: preparing; session 2C8442E1-D2D5-4655-9865-6013B5E37F5A |
| 74 → 75 | `process_read` | 2C8442E1-D2D5-4655-9865-6013B5E37F5A | success: running |
| 86 → 87 | `mcp_10_playwright_browser_tabs` | list | success |
| 98 → 99 | `mcp_10_playwright_browser_snapshot` | — | success |
| 109 → 110 | `mcp_10_playwright_browser_navigate` | http://localhost:4173 | success |
| 121 → 122 | `mcp_10_playwright_browser_snapshot` | — | success |
| 133 → 134 | `mcp_10_playwright_browser_console_messages` | — | success |
| 148 → 149 | `mcp_10_playwright_browser_click` | Who I Want to Be tab | failure: browser_observation_required |
| 160 → 161 | `mcp_10_playwright_browser_snapshot` | — | success |
| 171 → 172 | `mcp_10_playwright_browser_click` | Who I Want to Be tab | success |
| 183 → 184 | `mcp_10_playwright_browser_snapshot` | — | success |
| 195 → 196 | `mcp_10_playwright_browser_click` | Things I'd Love to Do With You tab | success |
| 206 → 207 | `mcp_10_playwright_browser_snapshot` | — | success |
| 218 → 219 | `mcp_10_playwright_browser_click` | Poems & Stories tab | success |
| 229 → 230 | `mcp_10_playwright_browser_snapshot` | — | success |
| 241 → 242 | `mcp_10_playwright_browser_click` | Home tab | success |
| 253 → 254 | `mcp_10_playwright_browser_snapshot` | — | success |
| 265 → 266 | `mcp_10_playwright_browser_click` | Receive a tiny hello button | success |
| 280 → 281 | `mcp_10_playwright_browser_tabs` | list | success |
| 291 → 292 | `mcp_10_playwright_browser_snapshot` | — | success |
| 307 → 308 | `workspace_write_text_file` | hello-world-hex/favicon.svg | success: 336 bytes; revision fe3449887af1 |
| 310 | `workspace_replace_text` | hello-world-hex/index.html | no tool receipt |

Terminal event: `run_failed`, sequence 311.

## Website - attempt 5

Run: `002EE1BE-F921-48F5-B7D0-D43468DBFA3B`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 54 → 55 | `workspace_list_directory` | hello-world-hex | success |
| 57 → 58 | `process_run` | /usr/bin/stat -c '%i %n' /private/var/folders/27/f97lbkd505s6jg6k0m1t_3m40000gn/T/.hex-workspace-write-transactions-v1-uid-501/runtime-slot-00/candidate-0c973ae0fb23b039c043ef68a33f2608 | failure: exit 1; /usr/bin/stat: illegal option -- c\nusage: stat [-FLnq] [-f format \\| -l \\| -r \\| -s \\| -x] [-t time… |
| 60 → 61 | `process_run` | /usr/sbin/lsof -nP -iTCP:4173 -sTCP:LISTEN | failure: exit 1 |
| 75 → 76 | `process_run` | /usr/bin/stat -f '%i %N' /private/var/folders/27/f97lbkd505s6jg6k0m1t_3m40000gn/T/.hex-workspace-write-transactions-v1-uid-501/runtime-slot-00/candidate-0c973ae0fb23b039c043ef68a33f2608 | success: exit 0; 37792782 /private/var/folders/27/f97lbkd505s6jg6k0m1t_3m40000gn/T/.hex-workspace-write-transactions-… |
| 78 → 79 | `process_run` | /usr/bin/stat -f '%i %N' /Users/horcrux/Documents/Hex/hello-world-hex/index.html | success: exit 0; 37792782 /Users/horcrux/Documents/Hex/hello-world-hex/index.html\n |
| 90 → 91 | `process_run` | /bin/rm /private/var/folders/27/f97lbkd505s6jg6k0m1t_3m40000gn/T/.hex-workspace-write-transactions-v1-uid-501/runtime-slot-00/candidate-0c973ae0fb23b039c043ef68a33f2608 | success: exit 0 |
| not dispatched → 102 | `process_run` | /usr/bin/stat -f '%l %i %N' /Users/horcrux/Documents/Hex/hello-world-hex/index.html | failure: not_executed |
| not dispatched → 104 | `process_run` | /usr/bin/test -e /private/var/folders/27/f97lbkd505s6jg6k0m1t_3m40000gn/T/.hex-workspace-write-transactions-v1-uid-501/runtime-slot-00/candidate-0c973ae0fb23b039c043ef68a33f2608 | failure: not_executed |

Terminal event: `run_failed`, sequence 106.

## Website - attempt 6

Run: `E201FD8B-3501-4A50-8043-D2E2380BCF10`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 67 → 68 | `workspace_read_text_file` | hello-world-hex/index.html | success: 1984 bytes; revision 99acb279662c |
| 70 → 71 | `workspace_list_directory` | hello-world-hex | success |
| 73 → 74 | `process_run` | /usr/sbin/lsof -nP -iTCP:4173 -sTCP:LISTEN | failure: task_operation_already_dispatched |

Terminal event: `run_failed`, sequence 76.

## Website - attempt 7

Run: `F4C1FF65-A3B2-4921-92EA-43F37A85A64B`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| not dispatched → 65 | `workspace_apply_patch` | hello-world-hex/index.html | failure: not_executed |
| not dispatched → 67 | `process_list` | — | failure: not_executed |

Terminal event: `run_failed`, sequence 69.

## Website - attempt 8

Run: `7389FE0C-5049-41F8-B5D4-2198641ED239`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| not dispatched → 67 | `workspace_apply_patch` | hello-world-hex/index.html | failure: invalid_tool_arguments |
| 79 | `workspace_apply_patch` | hello-world-hex/index.html | no tool receipt |

Terminal event: `run_failed`, sequence 80.

## Website - attempt 9

Run: `4FF3C766-79BA-4D81-861D-CCF04FCD168A`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 78 → 79 | `workspace_read_text_file` | hello-world-hex/index.html | success: 1984 bytes; revision 99acb279662c |
| 81 → 82 | `process_list` | — | success |
| not dispatched → 90 | `workspace_apply_patch` | hello-world-hex/index.html | failure: invalid_tool_arguments |
| 102 → 103 | `workspace_apply_patch` | hello-world-hex/index.html | failure: revision_conflict |
| 114 → 115 | `workspace_read_text_file` | hello-world-hex/index.html | success: 1984 bytes; revision 99acb279662c |
| 126 → 127 | `workspace_replace_text` | hello-world-hex/index.html | failure: io_failure |

Terminal event: `run_failed`, sequence 129.

## Website - attempt 10

Run: `253BA3DD-1256-42C7-AE50-75FD9565E2C8`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 87 → 88 | `workspace_apply_patch` | hello-world-hex/index.html | failure: task_operation_already_dispatched |

Terminal event: `run_failed`, sequence 90.

## Website - attempt 11

Run: `212671E2-1E84-4DB3-AED4-C6A9B9B64DAF`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 88 → 89 | `workspace_read_text_file` | hello-world-hex/index.html | success: 1984 bytes; revision 99acb279662c |
| 99 → 100 | `workspace_replace_text` | hello-world-hex/index.html | failure: task_operation_already_dispatched |

Terminal event: `run_failed`, sequence 102.

## Website - attempt 12

Run: `DC64297F-FEEF-48F6-AC84-D42A2CEB5996`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 95 → 96 | `workspace_apply_patch` | hello-world-hex/index.html | failure: revision_conflict |
| 107 → 108 | `workspace_read_text_file` | hello-world-hex/index.html | success: 1984 bytes; revision 99acb279662c |
| 120 → 121 | `workspace_changes` | — | success |
| not dispatched → 134 | `workspace_apply_patch` | hello-world-hex/index.html | failure: invalid_tool_arguments |
| 146 → 147 | `workspace_apply_patch` | hello-world-hex/index.html | failure: revision_conflict |
| 161 → 162 | `workspace_changes` | — | success |
| 178 → 179 | `workspace_read_text_file` | hello-world-hex/index.html | success: 1984 bytes; revision 99acb279662c |
| 181 → 182 | `process_list` | — | success |
| 193 → 194 | `workspace_apply_patch` | hello-world-hex/index.html | success |
| 205 → 206 | `process_start` | /usr/bin/python3 -m http.server 4173 --directory /Users/horcrux/Documents/Hex/hello-world-hex | success: preparing; session 3BC5723D-6CA6-4D75-98AA-BAECE53E4AEB |
| 216 → 217 | `process_read` | 3BC5723D-6CA6-4D75-98AA-BAECE53E4AEB | success: running |
| 228 → 229 | `mcp_10_playwright_browser_tabs` | list | failure: task_operation_already_dispatched |

Terminal event: `run_failed`, sequence 231.

## Website - attempt 13

Run: `6232824F-CA7A-4566-BCE7-559AD7F317EC`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 107 → 108 | `mac_list_applications` | — | success |

Terminal event: `run_failed`, sequence 110.

## Safari handoff - attempt 1

Run: `9756CCB3-2E15-42D6-B665-769597B953B7`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 13 → 14 | `mac_list_applications` | — | success |
| 25 → 26 | `mac_accessibility_snapshot` | com.apple.Safari | success |
| 43 → 44 | `artifact_search` | 0DBC2D40-876F-4193-AE1D-117F1DDBDFF6; query AXTextField; offset 0 | success |
| 46 → 47 | `artifact_search` | 0DBC2D40-876F-4193-AE1D-117F1DDBDFF6; query Address; offset 0 | success |
| 49 → 50 | `artifact_search` | 0DBC2D40-876F-4193-AE1D-117F1DDBDFF6; query AXToolbar; offset 0 | success |
| 61 → 62 | `artifact_read` | 0DBC2D40-876F-4193-AE1D-117F1DDBDFF6; offset 15800 | success |
| 73 → 74 | `mac_accessibility_action` | com.apple.Safari; set_value; path 0.0.2.2.2; value http://localhost:4173 | success |
| 84 → 85 | `mac_accessibility_snapshot` | com.apple.Safari | success |
| 96 → 97 | `mac_accessibility_action` | com.apple.Safari; confirm; path 0.0.2.2.2 | success |
| 108 → 109 | `mac_accessibility_snapshot` | com.apple.Safari | success |
| 120 → 121 | `artifact_search` | 6CA9A8C2-7837-4C2D-9EC3-CE2BD2EF9E6F; query localhost:4173; offset 0 | success |
| 132 → 133 | `mac_accessibility_action` | com.apple.Safari; focus; path 0.0.2.2.2 | success |
| 143 → 144 | `mac_accessibility_snapshot` | com.apple.Safari | success |
| 155 → 156 | `mcp_8_peekaboo_window` | Safari; list | success |
| 170 → 171 | `mcp_8_peekaboo_see` | PID:47517; observe; window 12522 | success |

Terminal event: `run_failed`, sequence 173.

## Text-only Safari handoff - attempt 1

Run: `2DF5E1DC-FDBC-4EE9-B5FD-D12B6CD71634`.

| Sequence | Hex tool | Target or operation | Result |
| --- | --- | --- | --- |
| 16 → 17 | `hex_inspect_self` | — | success |
| 19 → 20 | `mac_list_applications` | — | success |
| 31 → 32 | `process_run` | /usr/bin/open -a Safari http://localhost:4173 | success: exit 0 |
| 43 → 44 | `mac_accessibility_snapshot` | com.apple.Safari | success |
| 56 → 57 | `mac_activate_application` | com.apple.Safari | success |
| 71 → 72 | `mac_accessibility_snapshot` | com.apple.Safari | success |
| 74 → 75 | `mac_list_applications` | — | success |
| 86 → 87 | `artifact_search` | FF73DB12-31A4-4C18-9A0D-BAE531E7CC27; query localhost:4173; offset 0 | success |

Terminal event: `run_completed`, sequence 175.

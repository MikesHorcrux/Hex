# Security policy

Hex is experimental software with access to user-selected files and optional computer-control tools.
The current source alpha is the only version receiving fixes; there is no security support SLA.

Please report suspected vulnerabilities privately through the repository's GitHub **Security →
Report a vulnerability** control. Maintainers must enable private vulnerability reporting before
publishing this repository. If that control is unavailable, request that the maintainer enable it without including exploit
or credential details. Do not post a public issue containing an unpatched
security vulnerability or private data.

Include the affected commit, macOS/Xcode versions, prerequisites, expected and actual behavior,
and a minimal reproduction using synthetic data. Never include real provider tokens, passwords,
Keychain exports, conversation databases, or personal screenshots.

Approval rules are application policy, not an operating-system sandbox. Review external tools,
use a disposable workspace for testing, and supervise computer-control workflows. Unknown action
outcomes must remain visible; retrying an external action can have effects that are not reversible.

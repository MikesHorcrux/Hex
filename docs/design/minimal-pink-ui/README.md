# Approved Hex conversation design

The September 8 design selection uses neutral surfaces, the app icon’s pink accent, a quiet sidebar, subtle user bubbles and assistant text directly on the page. Codex chat views and a more minimal ChatGPT layout informed the direction.

[Approved reference](approved-reference.png)

This is a native SwiftUI implementation over the existing durable conversation model. Activity groups retain every tool receipt and artifact action. Paused work, queued messages, approvals and uncertain-outcome recovery keep their existing semantics. Search, archive and execution history remain available. The Automations shortcut opens the existing Settings section.

The reference attachment control is omitted until actual file/image admission is implemented. No placeholder attachment action is shipped. The broader Relic daily-use-interface ticket stays open for that and its remaining acceptance criteria.

Visual and live interaction qualification is recorded under `docs/verification` after checking the built app.

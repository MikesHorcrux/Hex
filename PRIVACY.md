# Data and privacy

Hex stores its configuration, conversations, tasks, memory, and artifacts locally. Provider credentials
are stored in the macOS Keychain under a shared group for the signed app and its resident helper.
Local storage is not a promise that all computation stays on the Mac.

- With OpenAI selected, the conversation/context and tool results needed for inference are sent to
  OpenAI. Screenshots or file contents can become part of that context when used by a task.
- With MLX selected, model inference runs locally; model installation and web/MCP tools may still
  contact external services. Models have their own licenses.
- Browser automation, screen control, subprocesses, and configured MCP servers can access data
  within their available authority. Review the selected workspace and approval mode carefully.
- Logs and artifacts can contain personal information. Sanitize them before attaching them to issues.

See [storage locations](docs/reference/configuration.md), [permissions](docs/concepts/permissions.md),
and [background work](docs/guides/resident.md). Quitting the window does not necessarily stop enabled
background work. Disable the resident in Hex before quitting when you want it stopped.

To remove a development installation, disable the resident, quit Hex, and remove the built app.
Keep a backup before removing `~/Library/Application Support/Hex`, which includes saved work and
managed tools. Use the app's credential-removal controls before uninstalling, or remove only the
Hex-specific entries in Keychain Access afterward. Do not delete unrelated Keychain items.
macOS privacy permissions can be revoked in System Settings → Privacy & Security.

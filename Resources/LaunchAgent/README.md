# Resident gateway resources

`com.lunarmothstudios.hex.gateway.plist` is the bundle-ready LaunchAgent definition used by the
`SMAppService` integration. Packaging must place it at
`Hex.app/Contents/Library/LaunchAgents/com.lunarmothstudios.hex.gateway.plist` and place the matching
gateway executable in the profiled helper bundle at
`Hex.app/Contents/Resources/HexGateway.app/Contents/MacOS/HexGateway`.

The job advertises the `com.lunarmothstudios.hex.gateway` Mach service, starts for the signed-in user,
and restarts after an unsuccessful exit with launchd throttling. A clean exit is not restarted, which
lets an explicit unregister or uninstall complete without a respawn loop.

These files do not install or register anything by themselves. Registration and removal go through
the app's visible `SMAppService` control so macOS can surface its approval state. Repository scripts
must not copy a plist into `~/Library/LaunchAgents` or call `launchctl` behind the user's back.

`com.lunarmothstudios.hex.gateway.plist.template` remains an inert legacy-development reference. It
is not packaged or registered.

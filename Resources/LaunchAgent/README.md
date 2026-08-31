# LaunchAgent template

`com.lunarmothstudios.hex.gateway.plist.template` is inert source material for a future, explicitly
approved always-on gateway installation flow. It is not a valid installed agent while its placeholder
paths remain, defaults to disabled, and no repository script loads or copies it into `~/Library`.

Before any future activation work, Hex must define an uninstall path, log retention, crash backoff,
upgrade behavior, and a visible user control. Registering a LaunchAgent is outside the current approval
boundary.

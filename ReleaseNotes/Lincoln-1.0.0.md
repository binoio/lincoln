# Lincoln 1.0.0

Initial release of **Lincoln** — the macOS GUI Dock and Menu Bar app for establishing and maintaining SSH tunnels through a gateway.

### Features
- **Tunnel Management**: Create, import, connect, disconnect, reconfigure and reorder SOCKS proxies and local/remote port forwards from the main window or the menu bar.
- **Terminal.app Console**: Connecting opens a Terminal window running ssh as a backgrounding ControlMaster; Duo, passphrase and host-key prompts are answered there with your usual shell, keys and agent.
- **Shared Connections**: Tunnels use the ControlPath from your ssh config, so terminal sessions and ProxyJump hops reuse them without a second Duo prompt — and tunnels started by hand appear in Lincoln.
- **Drop Detection**: Control sockets are polled and re-checked on network changes and wake; a dropped tunnel is flagged and notified, never reconnected unasked.
- **Non-Destructive Import**: Reads `~/.ssh/config` (including `Include`s) to offer host aliases and existing forwards; never writes your ssh configuration.
- **Durable State**: Tunnels and their desired state live in Application Support and survive reinstalling the app; masters keep running across Lincoln restarts.
- **Sparkle 2 Updates**: Automatic software update checks powered by Sparkle 2.
- **Apple Developer Notarized**: Signed and notarized with Hardened Runtime for macOS.

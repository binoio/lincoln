# Lincoln 1.0.0

Initial release of **Lincoln** — the macOS GUI Dock and Menu Bar app for establishing and maintaining SSH tunnels through a gateway.

### Features
- **Tunnel Management**: Create, import, connect, disconnect, reconfigure and reorder SOCKS proxies and local/remote port forwards from the main window or the menu bar.
- **Automatic Reconnection**: Dropped links are re-established with exponential backoff; network changes and wake from sleep restart connected tunnels immediately.
- **In-App Console**: ssh runs under a pseudo-terminal, so Duo passcode/push prompts, key passphrases and host-key confirmations are answered inside Lincoln.
- **Non-Destructive Import**: Reads `~/.ssh/config` (including `Include`s) to offer host aliases and existing forwards; never writes your ssh configuration.
- **Durable State**: Tunnels and their desired state live in Application Support and survive reinstalling the app; orphaned ssh processes are cleaned up at launch.
- **ControlMaster Sharing**: Optionally let terminal ssh sessions and ProxyJump hops reuse a tunnel's authenticated connection.
- **Sparkle 2 Updates**: Automatic software update checks powered by Sparkle 2.
- **Apple Developer Notarized**: Signed and notarized with Hardened Runtime for macOS.

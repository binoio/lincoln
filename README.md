# Lincoln

A macOS GUI Dock and Menu Bar app for establishing, maintaining, disconnecting and reconfiguring SSH tunnels — SOCKS proxies and port forwards through a gateway such as `tigressgateway`.

![Lincoln Icon](docs/images/icon.svg)

## Features

- **Tunnels as first-class objects**: Each tunnel is a host (an alias from `~/.ssh/config`, or a hostname) plus the SOCKS/local/remote forwards you want. Connect, disconnect, reconfigure and reorder them from the main window or the menu bar.
- **Maintained for you**: A dropped link is noticed by `ServerAlive` keepalives, network changes and sleep/wake, then re-established with exponential backoff. Each tunnel chooses whether to auto-reconnect (every retry may cost a Duo push).
- **Keys only, prompts in the app**: Password authentication is disabled. ssh runs under a pseudo-terminal Lincoln owns, so Duo passcode/push menus, key passphrases and host-key confirmations appear in a per-tunnel Console — with a notification and a menu bar badge when one is waiting for you.
- **Non-destructive**: Lincoln reads `~/.ssh/config` (and its `Include`s) to offer host aliases and import existing `DynamicForward`/`LocalForward` lines, and runs `ssh <alias>` with your normal configuration. It never writes to your ssh config.
- **Idempotent, durable state**: Tunnel definitions live in `~/Library/Application Support/Lincoln/tunnels.json` (schema-versioned; corrupt files are quarantined, never deleted). Trash the app, reinstall the same version a year later, and the tunnels — including which ones were connected — come back. Orphaned ssh processes from a previous Lincoln are found and stopped at launch.
- **Share a connection with your terminal**: Opt-in per tunnel, Lincoln acts as the `ControlMaster` for the host so a terminal `ssh della` (via `ProxyJump tg`) reuses the authenticated gateway connection and skips a second Duo prompt.
- **Dock & Menu Bar Modes**: Keep the main window in the Dock, or hide the Dock icon and drive everything from the menu bar extra.
- **Sparkle 2 Updates**: Integrated automatic software updates signed with EdDSA keys.
- **Developer ID & Notarization**: Native macOS app built with Swift and SwiftUI, signed with Apple Developer ID.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0+ to build from source

## Developer Workflow

```bash
# Build Debug configuration
zsh Scripts/build.sh

# Run Debug app
zsh Scripts/run.sh

# Run test suite (LincolnCore package tests + LincolnTests)
zsh Scripts/test.sh

# Run unit and UI test suite
zsh Scripts/test.sh --ui

# Run only the platform-independent LincolnCore tests (what CI runs on Linux)
zsh Scripts/test.sh --core
docker build -t lincoln-core-tests .

# Render icon assets
xcrun swift Scripts/generate_icon.swift
```

`LincolnCore/` is a pure-Foundation Swift package (tunnel model and store, `ssh_config` parser, ssh command builder, connection state machine, prompt detection). The app target in `Lincoln.xcodeproj` depends on it and adds the pty process, supervisors, SwiftUI views and Sparkle.

## Release Workflow

```bash
# Build, sign, notarize, generate Sparkle appcast, and publish release
zsh Scripts/release.sh
```

## License

MIT License. Copyright © 2026 Michael Bino.

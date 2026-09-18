# Lincoln

A macOS GUI Dock and Menu Bar app for establishing, maintaining, disconnecting and reconfiguring SSH tunnels — SOCKS proxies and port forwards through a gateway such as `tigressgateway`.

![Lincoln Icon](docs/images/icon.svg)

## Features

- **Tunnels as first-class objects**: Each tunnel is a host (an alias from `~/.ssh/config`, or a hostname) plus the SOCKS/local/remote forwards you want. Connect, disconnect, reconfigure and reorder them from the main window or the menu bar.
- **Terminal.app is the console**: Connecting opens a Terminal window running `ssh -M -N -f …` — Duo, passphrases and host keys are answered there, with your login shell, keys and agent. After authentication ssh backgrounds itself as a **ControlMaster** and the window can be closed.
- **Shared with your terminal by default**: Lincoln uses the `ControlPath` your ssh config already defines (via `ssh -G`), so a terminal `ssh della` through `ProxyJump tg` reuses the tunnel and skips a second Duo prompt. Tunnels you start by hand show up in Lincoln too.
- **Watched, not babysat**: Lincoln polls the control sockets (`ssh -O check`) and reacts to network changes and wake from sleep. A dropped tunnel is shown and notified — never reconnected behind your back, since every connection may cost a Duo push.
- **Keys only**: Password authentication is disabled on every tunnel Lincoln starts.
- **Non-destructive**: Lincoln reads `~/.ssh/config` (and its `Include`s) to offer host aliases and import existing `DynamicForward`/`LocalForward` lines, and runs `ssh <alias>` with your normal configuration. It never writes to your ssh config.
- **Idempotent, durable state**: Tunnel definitions live in `~/Library/Application Support/Lincoln/tunnels.json` (schema-versioned; corrupt files are quarantined, never deleted). Quit Lincoln and the masters keep running; relaunch a year later and it adopts what is still up and flags what is not.
- **Dock & Menu Bar Modes**: Keep the main window in the Dock, or hide the Dock icon and drive everything from the menu bar extra.
- **Sparkle 2 Updates**: Integrated automatic software updates signed with EdDSA keys.
- **Developer ID & Notarization**: Native macOS app built with Swift and SwiftUI, signed with Apple Developer ID.

## How a tunnel runs

```
Lincoln ──writes──▶ ~/Library/Application Support/Lincoln/commands/<name>.command
        ──opens──▶ Terminal.app ──runs──▶ ssh -M -N -f -o ControlPath=<from ssh -G> -D 1080 … tg
                                                │  (Duo / passphrase answered here)
                                                ▼
                                   control socket  ◀── ssh -O check / -O exit (Lincoln)
                                                   ◀── ssh della  (your terminal, via ProxyJump tg)
```

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

`LincolnCore/` is a pure-Foundation Swift package (tunnel model and store, `ssh_config` parser, ssh command builder and Terminal script, control-socket state machine). The app target in `Lincoln.xcodeproj` depends on it and adds the Terminal launcher, socket polling, SwiftUI views and Sparkle.

## Release Workflow

```bash
# Build, sign, notarize, generate Sparkle appcast, and publish release
zsh Scripts/release.sh
```

## License

MIT License. Copyright © 2026 Michael Bino.

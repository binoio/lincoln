# Lincoln 1.0.3

Lincoln 1.0.3 moves diagnostics out of the editor into a Get Info window.

### What's New
- **Get Info** (⌘I, also in the tunnel's ⋯ menu): a window per tunnel with the live status — state, control master pid, socket path and whether terminal sessions share it, forwards inherited from ssh config, last check and launch — plus the exact commands: the control master command, the terminal session command and the ssh_config snippet, each with a copy button.
- **Leaner editor**: the Status and Command preview sections and the reconnect help text are gone from the Configure form.
- **⋯ menu and Tunnel menu**: Copy ssh Command (⇧⌘C) and Copy ssh_config Snippet live there now; the header button is removed.

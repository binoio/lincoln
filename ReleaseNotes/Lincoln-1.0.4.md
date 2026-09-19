# Lincoln 1.0.4

Lincoln 1.0.4 fixes Duo logins and stops polling when nothing is connected.

### What's New
- **Duo works again**: The control master was started with `NumberOfPasswordPrompts=0`, which OpenSSH also applies to keyboard-interactive authentication — so gateways that require Duo after the key were refused with "Permission denied" before any prompt. Only `PasswordAuthentication=no` is pinned now; keys stay mandatory and Duo prompts appear in Terminal as intended.
- **No idle polling**: `ssh -O check` runs on a timer only while a tunnel is connected or in transition. When nothing is active, Lincoln watches the control-socket directories instead, so a master started by hand in a terminal is still adopted immediately; it also re-checks on network changes, wake and when the app comes to the front.

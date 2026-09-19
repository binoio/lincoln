# Lincoln 1.1.0

Lincoln 1.1.0 answers ssh's prompts in the app. No Terminal window is needed to connect.

### What's New
- **Prompts in Lincoln**: The control master is started by Lincoln with `SSH_ASKPASS` pointing at a bundled `lincoln-askpass` helper. When ssh needs you — a Duo passcode or push option, a key passphrase, an unknown host key — a Lincoln panel shows the prompt together with ssh's recent output (the Duo menu, the host-key fingerprint) and passes your answer straight back to ssh. Keys in your agent or keychain mean nothing is asked at all. Answers are never stored.
- **Settings › Connecting**: choose *Ask in Lincoln* (default) or *Open Terminal.app*, which keeps the previous flow.
- **Get Info** shows how a tunnel was launched ("by Lincoln (prompts answered in the app)").

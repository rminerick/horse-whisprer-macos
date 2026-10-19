# Per-application insertion

Open **Horse Whisprer → Settings… → Streaming**. The defaults apply to apps without overrides. Add an application to choose its streaming behavior, insertion method (paste, type, or copy only), and paste timing independently. **Use Defaults** removes all overrides for that application. Existing streaming overrides are preserved when upgrading.

Settings are chosen for the foreground app at the start of each dictation and remain fixed for that recording. Copy-only always suppresses live insertion. Paste timing applies to final paste, not live streaming or type/copy-only output.

## Apple Remote Desktop

Click **Add Apple Remote Desktop Preset** once. This chooses **Insert when finished**, **Paste, then type fallback**, and a one-second clipboard-sharing delay for Remote Desktop alone. Other applications retain their own settings. A preset button is also available for other remote clients you add.

Enable **Use Shared Clipboard** in Apple Remote Desktop. Click the remote text box, dictate, and stop. Horse Whisprer copies the transcript, briefly brings itself forward and returns to the same Remote Desktop window to refresh automatic sharing, waits for sharing, then sends one Command-V with explicit Command press and release events if the same local app and window remain focused. Apple Remote Desktop gets at least two seconds to share the clipboard, even if its saved delay is shorter; larger configured waits are preserved. Other remote clients retain the selected delay. The focus handoff happens for every transcript because Remote Desktop can otherwise retain the first clipboard until it is reactivated. If another app takes focus during the handoff, delivery stops without taking focus back. Automatic clipboard sharing remains enabled. The transcript stays on the clipboard so remote sharing is not raced by restoring the previous clipboard; immediate local paste retains its existing clipboard-restoration behavior.

Before dispatch, Horse Whisprer verifies that its clipboard still contains the complete transcript. Delayed paste is skipped if the app, window, clipboard, or delivery session changes before dispatch. A lost or incomplete clipboard is reported as a failure rather than a successful copy. It makes no typing fallback attempt, since remote delivery cannot be verified. Window checking uses the local Accessibility window only; it does not need the remote cursor or text. Moving between fields within the same remote window cannot be detected. Keep the intended remote text box focused until delivery finishes.

This is final-transcript insertion, not remote live streaming. The delay is a configurable wait, not an acknowledgement from the remote Mac. Automated tests cover dispatch ordering, preference selection, and interrupted delivery; actual clipboard synchronization depends on the remote session.

## Manual copying and retries

The popover and History copy buttons show **Copied** with a checkmark for two seconds after a verified local copy, or **Copy failed** if the complete text could not be read back. Each click restarts the feedback period. This confirms the local clipboard, not synchronization to a remote Mac.

**Insert Again** and the setup insertion test use the current target application's insertion method and paste timing, including Remote Desktop's delay and retained clipboard. They no longer bypass the per-application settings.

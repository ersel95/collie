# Collie

Two platforms, one repository: the **iOS** Swift package at the root, the **Android** port
in `Android/`. They ship on independent version lines and share the upload envelope.

- **iOS:** read `AGENTS.md` first — integration, development rules, and the behaviours that
  must be preserved. Details: `INTEGRATION.md` + the template `Integration/CollieIntegration.swift`.
- **Android:** read `Android/AGENTS.md` first. Details: `Android/INTEGRATION.md` + the template
  `Android/Integration/CollieIntegration.kt`. `Android/example/` is a working host app with
  Chucker wired in beside Collie — run it before changing anything.
- **Releasing either platform:** `RELEASING.md`.

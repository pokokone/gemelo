# Gemelo

**Gemelo** is a macOS desktop wrapper for the Gemini web app.

![Desktop](docs/desktop.png)

![Chat Bar](docs/chat_bar.png)

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by Google.
"Gemini" is a trademark of Google LLC.

Gemelo loads the official Gemini web app (`https://gemini.google.com`) in a native macOS shell.

## Upstream Attribution

This project is based on:
- https://github.com/alexcding/gemini-desktop-mac

## Functional Scope

- Native macOS wrapper around the Gemini web app
- Floating prompt panel (chat bar)
- Keyboard-first controls for local chat workflow

## Current Differences in This Fork

- App identity is configured as **Gemelo** in Xcode targets and resources.
- Local chat session management is included:
  - create local chat
  - switch local chat
  - close local chat
- Local chat shortcuts are configurable in Settings.
- Prompt input focus shortcut is configurable (default: `gi`).
- Initial page and newly created local chat pages attempt to set response mode to **Thinking** automatically.
- Prewarmed local chat sessions are used to reduce delay when creating a new local chat.
- Main window chat index indicator (`x / y`) is shown on hover in the title area.

## System Requirements

- macOS 14 or later
- Xcode 16+ (for local build)

## Build Locally

```bash
git clone https://github.com/pokokone/gemelo
cd gemelo
open Gemelo.xcodeproj
```

Then build/run with Xcode (`Product > Build` or `Product > Run`).

## Unsigned Build Note

Release artifacts produced by this repository are unsigned and not notarized.
On first launch, macOS may block the app until you allow it in:
- `System Settings > Privacy & Security`

## GitHub Release Automation

This repository includes a GitHub Actions workflow that:
- builds the macOS app in `Release`
- packages `.zip` and `.dmg`
- uploads build artifacts
- publishes files to GitHub Releases when you push a tag like `v1.0.0`

Workflow file:
- `.github/workflows/release.yml`

## License

This repository follows the upstream license terms.
See `LICENSE`.

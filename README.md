# Token Tracker

A macOS menu bar app (plus an iOS companion) that tracks Claude and ChatGPT/Codex plan usage across multiple accounts and notifies you as you approach or hit a limit.

## What it tracks

| Account type | How it signs in | Endpoint |
|---|---|---|
| Claude Code login | Reads Claude Code's Keychain item (read-only) | `api.anthropic.com/api/oauth/usage` |
| claude.ai session | Sign in inside the app; cookies stored in your Keychain | `claude.ai/api/organizations/{org}/usage` |
| Codex CLI login | Reads `$CODEX_HOME/auth.json` (one per `CODEX_HOME`) | `chatgpt.com/backend-api/wham/usage` |
| chatgpt.com session | Sign in inside the app; cookies stored in your Keychain | same, via `/api/auth/session` |

Each account shows its session (5h) and weekly windows, model-scoped weekly limits, plan, and reset countdowns. The menu bar shows the highest usage across accounts.

Alerts fire once per threshold per window (default 80%, 95%, 100%), plus an "available again" alert when a limited window resets.

These are undocumented endpoints that the official apps use, so they can change without notice. `Packages/UsageKit/Tests/UsageKitTests/Fixtures` holds real responses for reference.

## Multiple accounts

- **Claude:** use "Sign in to claude.ai…" once per account. Each sign-in uses an isolated browser session.
- **ChatGPT/Codex:** use "Sign in to chatgpt.com…", or give each account its own Codex home (`CODEX_HOME=~/.codex-work codex login`) and add that folder.

## Build

Requires macOS 26 / iOS 26 (Liquid Glass), Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make test        # UsageKit unit tests
make live-test   # hit the real endpoints with this Mac's Claude Code + Codex logins
make run         # build and launch the menu bar app
```

`make project` regenerates `TokenTracker.xcodeproj` from `project.yml` (the project file is not committed).

## iPhone companion

The Mac app publishes usage snapshots (never credentials) to your private iCloud database. The iOS app shows them and receives push alerts through CloudKit subscriptions.

iCloud and push need a **paid Apple Developer Program team**; personal teams can't sign them. Once you have one:

```sh
make run ICLOUD=YES   # Mac app with CloudKit
make ios              # iOS app
```

Then enable Settings → General → "Sync to iPhone via iCloud" on the Mac.

## Layout

```
Packages/UsageKit   Shared models, provider clients, parsers, alert logic, CloudKit sync, SwiftUI cards
Apps/Mac            Menu bar app (MenuBarExtra), settings, web sign-in
Apps/iOS            Companion dashboard + CloudKit push alerts
```

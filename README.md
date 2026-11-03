# Token Tracker

A menu bar app for your Mac that shows how much of your Claude and ChatGPT plan limits you've used, across as many accounts as you have. It pings you before you run out and again when you're good to go.

## What it tracks

| Account | How it gets in | Where it asks |
|---|---|---|
| Claude Code | Reads Claude Code's login from your Keychain. Never changes it. | `api.anthropic.com/api/oauth/usage` |
| claude.ai | You sign in inside the app. The cookie goes in your Keychain. | `claude.ai/api/organizations/{org}/usage` |
| Codex CLI | Reads `auth.json` from your Codex folder (one folder per account) | `chatgpt.com/backend-api/wham/usage` |
| chatgpt.com | You sign in inside the app. The cookie goes in your Keychain. | same, via `/api/auth/session` |
| Anthropic API | An Admin API key (`sk-ant-admin…`), kept in your Keychain | `/v1/organizations/usage_report/messages` and `/cost_report` |
| OpenAI API | An Admin API key, kept in your Keychain | `/v1/organization/usage/completions` and `/costs` |

For each subscription you get the 5-hour and weekly limits, any per-model weekly limits, your plan, and when each one resets. Claude accounts also show how the week's usage splits across Claude Code, chats and Cowork. API accounts show your organization's spend and tokens for today and the last 7 days (UTC days, as the providers report them). Regular API keys can't read usage, so these need an admin key. The menu bar shows the account you're using right now, colored green, amber or red. You can switch it to show whichever account is closest to its limit.

By default you get a notification at 80%, 95% and 100% of each limit, and another when a maxed-out account resets. You can change these in Settings.

The subscription endpoints aren't official APIs. They're what the Claude and ChatGPT apps use, so they can change without warning. Real responses are saved in `Packages/UsageKit/Tests/UsageKitTests/Fixtures`.

## More than one account

- **Claude:** use "Sign in to claude.ai…" once for each account. If one email is on several Claude plans (say, personal and work), you'll get to pick which ones to track.
- **ChatGPT/Codex:** use "Sign in to chatgpt.com…", or log each account into its own Codex folder (`CODEX_HOME=~/.codex-work codex login`) and add that folder.

## Building it

You need macOS 26, Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make test        # run the tests
make live-test   # check against your real Claude Code and Codex logins
make run         # build and open it from the build folder
make install     # build a release copy into /Applications and open it
```

`make project` rebuilds `TokenTracker.xcodeproj` from `project.yml`. The Xcode project isn't checked in.

## Where things are

```
Packages/UsageKit   Fetching, parsing, alert logic and the shared SwiftUI views
Apps/Mac            The menu bar app, settings and sign-in window
Apps/Shared         App icon and the Claude/OpenAI logos
```

## Privacy

Everything stays on your Mac. Logins live in your Keychain or in the CLIs' own files, and the app only talks to Anthropic and OpenAI. There's no server, no analytics and no tracking.

An iPhone app that syncs over iCloud is on the list. An earlier draft is in the git history.

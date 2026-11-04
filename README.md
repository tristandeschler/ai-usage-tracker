# Token Tracker

> Not affiliated with or endorsed by Anthropic or OpenAI. Claude and ChatGPT are their trademarks.

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

For each subscription you get the 5-hour and weekly limits, any per-model weekly limits, your plan, and when each one resets. API accounts show your organization's spend and tokens for today and the last 7 days (UTC days, as the providers report them), broken down by API key. Anthropic reports spend per key (it can lag by a few hours); OpenAI only reports tokens per key. Regular API keys can't read usage, so these need an admin key. The menu bar shows the account you're using right now, colored green, amber or red. You can switch it to show whichever account is closest to its limit.

Token Tracker checks GitHub for a new release once a day and shows an **Update** button in the menu (or installs it for you, if you turn that on in Settings). Before installing, it checks the download is signed with the same Developer ID and notarized by Apple, and refuses anything else.

There are also small, medium and large widgets for the desktop and Notification Center. They show the account you're using and how close each one is to its limit, and get their numbers from the app (never your logins).

By default you get a notification at 80%, 95% and 100% of each limit, and another when a maxed-out account resets. You can change these in Settings.

**Use at your own risk.** The subscription numbers come from endpoints the Claude and ChatGPT apps use, not public APIs. They can change or break without warning, and Anthropic or OpenAI could object to third-party apps reading them. The app checks at most every 5 minutes and identifies itself honestly, but it's still unofficial. Only the Admin API usage is an official, documented API. Real responses are saved in `Packages/UsageKit/Tests/UsageKitTests/Fixtures`.

## More than one account

- **Claude:** use "Sign in to claude.ai…" once for each account. If one email is on several Claude plans (say, personal and work), you'll get to pick which ones to track.
- **ChatGPT/Codex:** use "Sign in to chatgpt.com…", or log each account into its own Codex folder (`CODEX_HOME=~/.codex-work codex login`) and add that folder.

## Building it

You need macOS 26, Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

First, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and put in your Apple developer team ID and a bundle ID prefix. If you're signed in to Xcode with your Apple account, also turn on `TT_ENTITLEMENTS` there, which keeps logins and keys in the data protection keychain (readable only by this app, and never leaving this Mac).

```sh
make test        # run the tests
make live-test   # check against your real Claude Code and Codex logins
make run         # build and open it from the build folder
make install     # build a release copy into /Applications and open it
make release     # Developer ID-signed, notarized zip in build/release
PUBLISH=1 make release   # …and publish it as a GitHub release
```

Releases are built and published from a Mac. See [RELEASING.md](RELEASING.md).

`make project` rebuilds `TokenTracker.xcodeproj` from `project.yml`. The Xcode project isn't checked in.

## Where things are

```
Packages/UsageKit   Fetching, parsing, alert logic and the shared SwiftUI views
Apps/Mac            The menu bar app, settings and sign-in window
Apps/Widget         Desktop and Notification Center widgets
Apps/Shared         App icon and the Claude/OpenAI logos
```

## Privacy

Everything stays on your Mac. Logins live in your Keychain, or in Claude Code's and Codex's own files (read, never changed), and logins and keys only ever go to the provider they belong to. The app talks to Anthropic and OpenAI for usage, and to GitHub to check for and download updates. There's no server, no analytics and no tracking. When you sign in through the app, it keeps only the login cookie and Cloudflare's, not the rest of the site's cookies.

Admin API keys can do more than read usage, so give Token Tracker its own key and revoke it if you stop using the app. See [SECURITY.md](SECURITY.md) to report a problem.

## License

MIT. See [LICENSE](LICENSE).

An iPhone app that syncs over iCloud is on the list. An earlier draft is in the git history.

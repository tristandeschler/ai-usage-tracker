# Security

Token Tracker holds sensitive things: Claude and ChatGPT session cookies, and Admin API keys that can manage an organization. Please report anything that could expose them privately, not in a public issue.

## Reporting

Use GitHub's private vulnerability reporting: the **Security** tab → **Report a vulnerability**. You'll get a reply within a week. Please include steps to reproduce and the version or commit you tested.

## What the app does with your credentials

- Logins, cookies and keys are stored in the macOS Keychain, never in files or settings.
- They're only sent over HTTPS to the provider they belong to: `api.anthropic.com`, `claude.ai`, `chatgpt.com` or `api.openai.com`.
- Claude Code's and Codex's own logins aren't read or changed.
- The only other place the app connects to is GitHub, to check for and download updates, and that sends no credentials.
- The app has no server, no analytics and no third-party dependencies.

## For contributors

Changes that touch the Keychain, networking, the URLs the app calls, or what gets stored get extra review. A pull request that sends data to a new domain will be asked why.

# Releasing

Releases are automatic. Every merge to `main` that changes the app (anything under `Apps/`,
`Packages/UsageKit/Sources/`, `project.yml` or `Config/Base.xcconfig`) runs the **Release**
workflow, which:

1. picks the next version: one patch above the latest tag, or `MARKETING_VERSION` in
   `project.yml` if that's higher (bump it in your PR for a minor or major release),
2. runs the tests,
3. builds, signs with Developer ID, notarizes with Apple and staples the app,
4. publishes a GitHub release with the zip and its SHA-256, using the merge commit's message
   as the release notes.

Installed copies pick the release up within a day through the in-app updater. Docs-only
merges don't release. To release by hand, run the workflow from the Actions tab.

## One-time setup

The workflow signs and notarizes as your Apple developer team through an **App Store Connect
API key**:

1. In [App Store Connect → Users and Access → Integrations → Team Keys](https://appstoreconnect.apple.com/access/integrations/api),
   create a key with the **Admin** role (needed to manage Developer ID signing). Download the
   `.p8` file and note the **Key ID** and **Issuer ID**.
2. Add them as repository secrets:
   ```sh
   gh secret set ASC_KEY_P8 < AuthKey_XXXXXXXXXX.p8
   gh secret set ASC_KEY_ID --body XXXXXXXXXX
   gh secret set ASC_ISSUER_ID --body xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```
3. Add your team and bundle prefix as repository variables (not secret):
   ```sh
   gh variable set DEVELOPMENT_TEAM --body ABCDE12345
   gh variable set TT_BUNDLE_PREFIX --body com.yourname
   ```

Then delete the `.p8` from your Downloads; Apple won't let you download it again, so keep a
copy in your password manager if you want one.

## Releasing locally

`PUBLISH=1 make release` does the same thing from your Mac, signing and notarizing through
the Apple account Xcode is signed in to.

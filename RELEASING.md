# Releasing

Releases are built on a Mac signed in to Xcode with the Apple account that owns the Developer ID. No signing keys or Apple credentials are stored on GitHub.

1. In a pull request, raise `MARKETING_VERSION` in `project.yml`, and merge it once CI passes.
2. Check out the latest `main` with no local changes.
3. Run:
   ```sh
   PUBLISH=1 make release
   ```

That builds the app, signs it with Developer ID, notarizes it with Apple, staples the result, and publishes a GitHub release with the zip and its SHA-256. It stops early if your checkout doesn't match `main` or the version is already released.

Installed copies find the new release within a day through the in-app updater.

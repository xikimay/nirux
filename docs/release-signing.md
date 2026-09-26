# Release Signing

Nirux releases are built by GitHub Actions, signed with a Developer ID
Application certificate, submitted to Apple's notary service, stapled, then
signed for Sparkle updates.

## Required Apple Setup

You need an active Apple Developer Program membership.

Create a `Developer ID Application` certificate for direct macOS distribution
outside the Mac App Store. You can create it from Xcode:

1. Open Xcode.
2. Go to `Settings` > `Accounts`.
3. Select your Apple Developer account.
4. Open `Manage Certificates`.
5. Add a `Developer ID Application` certificate.

Then export the certificate and private key from Keychain Access:

1. Open `Keychain Access`.
2. Find your `Developer ID Application: ... (TEAMID)` certificate.
3. Expand it and make sure the private key is present.
4. Select both certificate and private key.
5. Export as `.p12`.
6. Set a strong export password and store it in 1Password.

## GitHub Actions Secrets

Set these secrets on `xikimay/nirux`:

```text
SPARKLE_PRIVATE_KEY
APPLE_DEVELOPER_ID_APPLICATION
APPLE_DEVELOPER_ID_CERTIFICATE_BASE64
APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD
APPLE_ID
APPLE_APP_SPECIFIC_PASSWORD
APPLE_TEAM_ID
```

`SPARKLE_PRIVATE_KEY` already contains the Sparkle EdDSA private key.

`APPLE_DEVELOPER_ID_APPLICATION` must match the signing identity exactly, for
example:

```text
Developer ID Application: Example Name (ABCDE12345)
```

`APPLE_TEAM_ID` is the 10-character Apple Developer team ID in parentheses.

`APPLE_APP_SPECIFIC_PASSWORD` is an app-specific password for the Apple ID used
with `notarytool`. Create it from appleid.apple.com.

Encode the `.p12` certificate for GitHub:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Then set the secrets:

```bash
gh secret set APPLE_DEVELOPER_ID_CERTIFICATE_BASE64 --repo xikimay/nirux
gh secret set APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD --repo xikimay/nirux
gh secret set APPLE_DEVELOPER_ID_APPLICATION --repo xikimay/nirux
gh secret set APPLE_ID --repo xikimay/nirux
gh secret set APPLE_APP_SPECIFIC_PASSWORD --repo xikimay/nirux
gh secret set APPLE_TEAM_ID --repo xikimay/nirux
```

Paste each value when prompted.

## Local Verification

List local signing identities:

```bash
security find-identity -v -p codesigning
```

Create a Developer ID-signed bundle locally:

```bash
swift build -c release
NIRUX_CODESIGN_IDENTITY="Developer ID Application: Example Name (ABCDE12345)" \
  ./scripts/bundle.sh "dev" "1"
```

Submit and staple locally:

```bash
xcrun notarytool submit Nirux.app.zip \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --wait

xcrun stapler staple Nirux.app
xcrun stapler validate Nirux.app
spctl --assess --type execute --verbose=4 Nirux.app
```

After stapling, recreate the zip before Sparkle signing:

```bash
rm -f Nirux.app.zip
ditto -c -k --keepParent Nirux.app Nirux.app.zip
```

## Nightly Releases

Every push to `main` publishes two prereleases from the same build:

- `nightly-YYYY.MM.DD-<sha>`: one immutable release per built commit, holding
  `Nirux.app.zip` and an `appcast.xml` whose enclosure points at that same zip.
  The workflow keeps the 20 most recent and deletes older ones, with their tags.
- `nightly`: the rolling release, recreated on every build. Sparkle's
  `SUFeedURL` reads `nightly/appcast.xml`, which points at the newest dated
  release's zip.

Each dated release's title carries the build number that `About Nirux` shows in
parentheses, so you can match an installed build to its release.

Sparkle checks for updates every hour. With `Nirux > Install Updates
Automatically` checked (the default), it downloads and installs new builds
silently. Uncheck it to have Sparkle ask first; the choice is kept in user
defaults and survives updates.

## Rolling Back A Broken Nightly

Sparkle never installs a build older than the one running. A rollback therefore
has two halves: pin a good build on your Mac now, then ship a fix so every
install moves past the broken one.

### 1. Pin a good build on your Mac

1. Uncheck `Nirux > Install Updates Automatically`. Otherwise Sparkle
   reinstalls the newest nightly within the hour. If the broken build does not
   launch or predates that menu item, run instead:

   ```bash
   defaults write com.xikimay.nirux SUAutomaticallyUpdate -bool false
   ```

2. Pick the last good build among the dated releases:

   ```bash
   gh release list --repo xikimay/nirux
   ```

3. Back up your state first: an older build ignores state fields it does not
   know about and drops them on its next save.

   ```bash
   ditto ~/Library/Application\ Support/nirux ~/nirux-state-backup-$(date +%Y%m%d%H%M)
   ```

4. Quit Nirux, then install the chosen build. Moving the broken app aside
   keeps it around for debugging:

   ```bash
   TAG=nightly-YYYY.MM.DD-<sha>
   DIR=$(mktemp -d)
   gh release download "$TAG" --repo xikimay/nirux --pattern Nirux.app.zip --dir "$DIR"
   ditto -x -k "$DIR/Nirux.app.zip" "$DIR"
   mv /Applications/Nirux.app "/Applications/Nirux-broken-$(date +%Y%m%d%H%M).app"
   ditto "$DIR/Nirux.app" /Applications/Nirux.app
   ```

Sparkle still reports the newer build; choose `Skip This Version` or `Remind
Me Later`. Once a fixed nightly is out, check `Install Updates Automatically`
again, or run `defaults delete com.xikimay.nirux SUAutomaticallyUpdate` to
return to the default.

### 2. Fix forward for every install

Revert the offending change on `main` through a pull request. Its nightly gets
a higher build number than the broken one, so every install updates to it.
This is the only way to move installs that already took the broken build.

### 3. Optional: stop the broken build from spreading

While the fix builds, point the rolling feed back at the last good build.
Installs older than it update to it; installs already on the broken build see
nothing newer and stay put. The next push to `main` replaces both files.

```bash
TAG=nightly-YYYY.MM.DD-<sha>
DIR=$(mktemp -d)
gh release download "$TAG" --repo xikimay/nirux --pattern appcast.xml --pattern Nirux.app.zip --dir "$DIR"
gh release upload nightly "$DIR/appcast.xml" "$DIR/Nirux.app.zip" --repo xikimay/nirux --clobber
```

The `nightly` release notes keep describing the broken build until then.

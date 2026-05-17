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

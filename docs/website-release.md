# Website releases

The direct-download app uses `com.codemoore.pomodoro.menubar` and updates from
`https://quietpomodoro.com/downloads/mac/appcast.xml`. Keep both stable after
the first public release. It supports Intel and Apple silicon on macOS 14+.

## Signing setup

- Copy `signing.example.sh` to `.signing.local.sh` and set your Developer ID
  Application identity and team ID, or provide `SIGN_IDENTITY` and `TEAM_ID`
  through the environment. The local file is ignored by Git; keep passwords
  and private keys in Keychain. Local builds without an identity use ad-hoc
  signing; website releases require a Developer ID identity.
- Notarization credentials: Keychain profile `pomodoro`. To set up a new Mac,
  run `xcrun notarytool store-credentials pomodoro` and follow the secure prompts.
- Sparkle private key: login Keychain, account `com.codemoore.pomodoro.menubar`.
  Only `sparkle_public_key.txt` is committed. `./setup-sparkle-key.sh` checks the
  Keychain public key without replacing an existing key.
- Back up the Sparkle key using the bundled `generate_keys --account
  com.codemoore.pomodoro.menubar -x /secure/location/private-key` command. Keep
  that backup in a password manager or encrypted storage, outside the repository.
  Import on another release Mac with the same account and `-f` instead of `-x`.
  A new key cannot authenticate updates for an already released public key.

Older development copies used a placeholder feed and must be replaced
manually once with a website release.

## Build and verify

```sh
swift package resolve
./release.sh --check
swift test --disable-sandbox
python3 -m unittest discover -s Tests -p 'test_*.py'
./release.sh 1.3
```

Use a new marketing version for each release. 1.2 is the first public
release; 1.2.1 was notarized from an older checkout but never published, so
don't reuse that number either. Build numbers increase by UTC
timestamp; `BUILD_NUMBER` can override this but must exceed the existing feed.
Keep the latest published `releases/appcast.xml` locally for subsequent releases.
On a fresh checkout, copy it from the website repository's
`site/dist/downloads/mac/appcast.xml` first, so the new feed keeps the older
entries and the build-number check runs.
The script rejects insecure URLs, missing credentials, mismatched Sparkle keys,
reused archive names and unsigned or rejected notarization results. It never
changes the source plist's version or replaces the local running app.

The script builds `dist/Direct/Pomodoro.app` with the existing app icon and
privacy manifest, signs all nested code with hardened runtime and timestamps,
notarizes and staples the app, then creates a signed and notarized drag-to-install
DMG. If disk-image creation is unavailable, it creates a ZIP containing the
stapled app. Gatekeeper and ticket validation must pass before an archive reaches
`releases/`. Apple submission results are retained in `dist/Direct/`.

Sparkle signs the final archive bytes. The generated appcast is independently
checked for the correct download URL, size, versions and Ed25519 signature
against the public key embedded in the built app. Successful output includes
the archive, its SHA-256 checksum and `releases/appcast.xml`.

## Publish on quietpomodoro.com

In the website repository, copy the release archive, checksum and appcast into
`site/dist/downloads/mac/`.
The website build copies those bytes to `site/build/downloads/mac/`; the feed
revalidates on every request and versioned archives are cached as immutable.
Do not overwrite an archive URL that has already been published. No private
keys, app-specific passwords, or notarization logs belong in that directory.

Run the website's `npm run build:ci`, commit the download files, and publish
through its existing Cloudflare Workers Builds workflow. Confirm that the
successful build matches the pushed commit, then fetch the public archive and
feed and verify their bytes against the local files.

## Check on a Mac

Install the DMG's app in Applications and open it. Existing development tasks
and settings migrate once from `local.pomodoro.menubar`; existing destination
values take precedence and the original preferences remain intact. macOS may
ask again for calendar access because the bundle ID changed.

Verify the menu-bar timer, task planning and optional calendar access. Check
for Updates should fetch the published feed and report the current version.
An older installed build must successfully update to a newer notarized build
before the complete update-install flow can be considered verified.

References: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [Sparkle publishing](https://sparkle-project.org/documentation/publishing/).

# Mac App Store release

Everything the code needs for the store is in place: an App Store flavour with
no Sparkle, sandboxed, with its own bundle ID, a compiled icon and a privacy
manifest, built and packaged by `./build-appstore.sh`. What's left is account
setup that only the account holder can do, and the listing.

## Decisions to confirm

Defaults were picked so the build works; change them before the first upload.

| What | Default | Where to change it |
|---|---|---|
| Bundle ID | `com.codemoore.pomodoro.menubar` | `BUNDLE_ID` in `build-appstore.sh`. **Permanent** once an App Store Connect record uses it. |
| Team ID | Required; no default | Set `TEAM_ID` to the 10-character ID in your Apple Developer account's Membership details. Use the team that owns the certificates and provisioning profile. |
| Store name | your choice, see `app-store-listing.md` | App Store Connect. Must be unique on the store, 30 characters max. The menu bar and Finder still say "Pomodoro". |
| Price | Free | App Store Connect, Pricing and Availability |
| Icon | the Quiet Pomodoro icon (`Resources/AppIcon.icon`, copied from the iOS project) | Replace `Resources/AppIcon.icon` with another Icon Composer file. Reusing it on a separate listing is a brand call. |
| Version | 1.2, build number from the date and time | `VERSION` / `BUILD_NUMBER` when running the script |
| Category | Productivity | `LSApplicationCategoryType` in the script, and App Store Connect |

## One-time setup (developer account)

Copy `signing.example.sh` to `.signing.local.sh` and set your team ID, or
provide `TEAM_ID` through the environment. This local configuration is ignored
by Git. Keep certificates, provisioning profiles and private keys outside the
repository; never commit them.

1. **Register the App ID.** developer.apple.com → Certificates, Identifiers &
   Profiles → Identifiers → **+** → App IDs → App. Platform **macOS**, explicit
   Bundle ID `com.codemoore.pomodoro.menubar`. No capabilities need ticking:
   the sandbox and calendar access are entitlements, not capabilities.
2. **Create the two certificates.** Easiest from Xcode: Settings → Accounts →
   your team → Manage Certificates → **+** → **Apple Distribution**, then
   **+** → **Mac Installer Distribution**. A "Developer ID Application"
   certificate is for downloads outside the store.
3. **Create the provisioning profile.** Profiles → **+** → Distribution →
   **Mac App Store Connect** → pick the App ID → pick the Apple Distribution
   certificate → download the `.provisionprofile`.
4. **Create the app record.** appstoreconnect.apple.com → Apps → **+** →
   New App → platform **macOS**, the store name, primary language, the bundle
   ID from step 1, and a SKU (any private reference, e.g. `pomodoro-mac-1`).

## Each release

1. Build and package, pointing at the profile from step 3. Replace
   `YOUR_TEAM_ID` with your team's 10-character ID:

   ```sh
   TEAM_ID=YOUR_TEAM_ID PROFILE=~/Downloads/<name>.provisionprofile ./build-appstore.sh
   ```

   It finds the certificates in your keychain, checks the bundle (no Sparkle,
   sandbox and calendar entitlements present) and writes
   `dist/AppStore/Pomodoro-<version>-<build>.pkg`. It says whether the package
   is uploadable.
2. Upload with **Transporter** (free, Mac App Store): sign in, drag the
   `.pkg` in, Deliver. Xcode's Organizer works too.
3. In App Store Connect, once the build has processed: optionally test it with
   TestFlight for Mac, then add it to the version, fill in the listing
   (`app-store-listing.md`), answer App Privacy, and submit for review.

## Before submitting, check by hand

The store build is sandboxed. It shares its bundle ID with the website build,
but keeps its data in its own container, so it starts empty and macOS asks
for calendar access again:

- Open `dist/AppStore/Pomodoro.app`, click **Connect**, allow calendar access,
  and check today's meetings appear. This is the one thing the sandbox could
  break and only a real permission prompt can test.
- Settings: the Calendars list shows your calendars; there is no
  "Check for Updates…".
- Quit it afterwards so you don't have two Pomodoros in the menu bar. Its data
  lives in `~/Library/Containers/com.codemoore.pomodoro.menubar`, separate from
  the copy you use day to day.

## App Privacy (App Store Connect)

- **Data collection:** "No, we do not collect data from this app." Tasks and
  settings stay on the Mac; calendar events are read on the device and never
  sent anywhere. This matches `Resources/PrivacyInfo.xcprivacy`.
- **Privacy policy URL:** required. A draft is in `privacy-policy.md`; it
  needs hosting somewhere public (the Quiet Pomodoro legal site would do).

## Review notes (paste into "Notes" for App Review)

> Pomodoro is a menu bar app: it has no Dock icon or main window. After
> launch, click its item in the menu bar (it reads "Plan your day" until a task
> is added) to open it. Calendar access is optional. Press Connect to let it
> read today's meetings and plan tasks around them; without it the planner
> works with tasks alone. No account or sign-in is needed. Quit is in the
> bottom-left corner of the panel.

## Not done yet

- **Screenshots**: drafts are in `screenshots/` at 2880×1800; the store needs
  at least one.
- **Launch at login**: not required by the store, but people expect it from a
  menu bar app. Would need a Settings toggle using `SMAppService`.
- **The direct-download build** now uses the permanent bundle ID and the
  Quiet Pomodoro download feed. See `website-release.md` for its separate
  signing, notarization and publishing workflow. It migrates development
  preferences once; the App Store build remains sandboxed.
- **Build number**: `build.sh` stamps a 14-digit number, too large for App
  Store Connect. The store script uses `YYYYMMDD.HHMM` instead; Transporter's
  checks will confirm it's accepted.

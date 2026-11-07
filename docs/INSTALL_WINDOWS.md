# Install on your iPhone from Windows (no Mac)

Total cost: $0. You need a GitHub account (free), your Apple ID, a USB cable, about 30 minutes
the first time.

## 1. Build the app in the cloud (GitHub Actions)

1. Create a free account at github.com if you don't have one.
2. Install **GitHub Desktop** (desktop.github.com) and sign in.
3. Unzip `PortalAlley.zip` somewhere, e.g. `Documents\PortalAlley`.
4. GitHub Desktop → *File → Add local repository…* → choose that folder → when it says it isn't a
   repository, click *create a repository* → *Create repository* → *Publish repository*.
   - **Public** repo: standard macOS runner minutes are free and unlimited.
   - **Private** repo: the free plan includes 2,000 minutes/month but macOS counts 10×, so about
     200 macOS minutes. One build takes roughly 6-12 minutes, so that is still enough.
5. On github.com open the repository → **Actions** tab. Publishing triggers the
   *Build iOS app (unsigned IPA)* workflow (or press *Run workflow*).
6. When the **build** job is green, open the run and download the artifact
   **PortalAlley-unsigned-ipa** (a zip containing `PortalAlley-unsigned.ipa`). Unzip it.
   - If a job is red, download **build-log** / **core-test-log** from the same page and send them
     to me. The code has not been compiled before this point.

## 2. Prepare Windows (once)

1. Uninstall the Microsoft Store versions of iTunes and iCloud if present (and the
   "Apple Devices" app if it stops your phone from appearing).
2. Install the **non-Store (web) versions of iTunes and iCloud** from Apple (links on
   sideloadly.io). Reboot.
3. Install **Sideloadly** from sideloadly.io.
4. Plug in the iPhone, unlock it, tap **Trust This Computer**, open iTunes once so the phone appears.

## 3. Prepare the iPhone (once)

- Settings → Privacy & Security → **Developer Mode** → on → restart → confirm.
  (Required on iOS 16+ for apps signed with a development certificate.)

## 4. Install

1. Open Sideloadly, drag `PortalAlley-unsigned.ipa` onto it.
2. Enter your Apple ID (a secondary Apple ID is fine). Leave the bundle ID as is.
3. Start. Enter the 2FA code if asked.
4. On the iPhone: Settings → General → **VPN & Device Management** → your Apple ID → **Trust**.
5. Open **Portal**. Allow camera access.

## Limits of free signing

- The app stops opening after **7 days**. Re-run step 4 with the same Apple ID; Sideloadly
  overwrites it in place. Sideloadly can also refresh automatically while the phone is reachable.
- Free Apple IDs allow **3 sideloaded apps** at once.
- No App Store, TestFlight or paid membership is involved.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Sideloadly doesn't see the phone | web iTunes/iCloud (not Store), unlock + trust, other cable/port |
| "Untrusted developer" | step 4.4 |
| App won't open after a week | re-sign (7-day limit) |
| Black screen / camera message | Settings → Privacy → Camera → Portal on |
| Portal shows grey/flat surfaces | developer panel → "Shader" lines: shader fallback happened; send me the report |

# Getting Cueframe onto TestFlight

The `TestFlight` GitHub Actions workflow builds a signed release and uploads it. It needs a one-time setup in Apple's sites and four repository secrets.

## One-time setup

1. **Register the bundle ID.** developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App. Description "Cueframe", Bundle ID **Explicit**: `com.mattbrown0406.cueframe`. No extra capabilities needed.
2. **Create the app record.** appstoreconnect.apple.com → Apps → **+** → New App. Platform iOS, any name you like (it must be unique on the App Store, e.g. "Cueframe Teleprompter"), bundle ID `com.mattbrown0406.cueframe`, SKU `cueframe`.
3. **Create an API key.** App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → **+**. Access: **Admin** (needed so the build can create its own signing certificate). Download the `.p8` file (Apple only lets you download it once). Note the **Key ID** and the **Issuer ID** shown above the list.
   If you already have an Admin key and its `.p8` file (for example from Expo), you can reuse it.
4. **Find your Team ID.** developer.apple.com → Account → Membership details → Team ID (10 characters).
5. **Add the secrets.** GitHub → this repo → Settings → Secrets and variables → Actions → New repository secret:

   | Name | Value |
   | --- | --- |
   | `APPLE_TEAM_ID` | Team ID |
   | `ASC_KEY_ID` | Key ID |
   | `ASC_ISSUER_ID` | Issuer ID |
   | `ASC_KEY_P8` | The whole text of the `.p8` file, including the BEGIN and END lines |

## Each upload

Runs automatically on every push to `main`, or from Actions → TestFlight → Run workflow. The build number is the workflow run number, so it always goes up. After the upload, Apple takes about 10 to 30 minutes to process the build; then it appears in the TestFlight app for internal testers.

The app's version is `MARKETING_VERSION` in `project.yml` (now 0.1.0).

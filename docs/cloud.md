# Cloud backup of projects (Supabase)

Editor projects, in progress and finished, are backed up to a Supabase table so they survive app
updates, a deleted project file, or (later) a move to a new phone.

## What goes to the cloud

- One row per project in `public.projects`: name, status (`in_progress` / `finished`), canvas,
  quality, length, clip count, dates, and `data`, the full edit as JSON.
- **Footage** (takes, imported clips, music, voiceovers, logos, brand intro/outro) goes to the private
  Storage bucket `footage`, at `<user id>/<path inside Documents>`. See "Footage" below.

## How it works

- The phone is the source of truth. `ProjectStore` saves locally first, so the app works offline.
- `ProjectSync` queues every save and delete, uploads when there is a connection (a few seconds
  after an edit, whenever the app comes to the front, and every minute after a failure), then pulls
  rows changed since its last pull. A project missing on the phone but present in the cloud comes back.
- Local changes that haven't uploaded yet always win over the cloud copy.
- Deletes are soft (`deleted_at`) so other devices find out. Deleting a project on another device
  removes the project from the list but leaves its media files alone.
- A project becomes **Finished** after a successful export. Long-press a project to mark it
  finished or move it back. The Edit tab can filter All / In progress / Finished.

## Footage

- `FootageSync` runs after each project sync. It uploads every file a project (or the brand kit)
  uses, plus takes in Recordings, then downloads files a project needs but the phone lacks.
- Wi-Fi only by default (Low Data Mode also pauses it). Cloud backup settings (cloud icon on the
  Edit tab) can allow cellular or turn footage backup off.
- Uploads use Supabase's resumable (TUS) endpoint in 6 MB chunks, so an interrupted 4K take resumes.
- Files modified in the last 30 seconds are skipped (a take still recording).
- A cloud file is deleted only when no project uses it and it is gone from the phone too.
- Recording bitrates: 1080p 16 Mbps (about 120 MB a minute), 4K 50 Mbps H.264 or 35 Mbps HEVC
  (about 260 to 375 MB a minute).
- Supabase Pro includes 100 GB of storage, then about $0.021 per GB a month; 250 GB of downloads a
  month are included, then $0.09 per GB.
- The project's global upload size limit (Storage settings) must be larger than the biggest take.

## Sign-in

No sign-in screen. Each install signs in anonymously with Supabase Auth and keeps the session in the
Keychain, which survives app updates. Row level security limits every user to their own rows.
To move to a new phone, sign in with email in Cloud backup settings: Supabase emails a one-time code.
Signing in on the new phone with the same email restores projects and footage. The Supabase email
templates "Magic Link" and "Confirm signup" must include `{{ .Token }}` so the email shows the code.
Signing in switches this phone to that account and uploads what is on the phone to it.

The Supabase project must have **Authentication → Sign In / Providers → Allow anonymous sign-ins** turned on.

## Turning it on

The app uses the Supabase project **CueFrame** (`ubbuenuirzpkdmakihrk`, us-east-2), where the migration is applied.

Set two build settings in `project.yml` (target `Cueframe`):

```yaml
SUPABASE_URL: "https://<ref>.supabase.co"
SUPABASE_PUBLISHABLE_KEY: "sb_publishable_..."
```

The publishable key is designed to ship inside apps. Leave either blank and cloud backup is off.
The schema is in `supabase/migrations/`.

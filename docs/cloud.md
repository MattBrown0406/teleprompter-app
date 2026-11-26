# Cloud backup of projects (Supabase)

Editor projects, in progress and finished, are backed up to a Supabase table so they survive app
updates, a deleted project file, or (later) a move to a new phone.

## What goes to the cloud

- One row per project in `public.projects`: name, status (`in_progress` / `finished`), canvas,
  quality, length, clip count, dates, and `data`, the full edit as JSON.
- **Not** the video, music or voiceover files. Those stay on the phone. A 4K minute is around
  200 to 400 MB, so uploading media is a separate decision (cost and upload time).

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

## Sign-in

No sign-in screen. Each install signs in anonymously with Supabase Auth and keeps the session in the
Keychain, which survives app updates. Row level security limits every user to their own rows.
Later, an Apple or email sign-in can be linked to the same account so projects follow you to a new phone.

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

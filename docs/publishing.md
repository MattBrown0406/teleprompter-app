# Posting and insights

The **Post** tab is a content calendar for TikTok, Instagram and Facebook, with posting reminders,
one-tap handoff to each app, and insights on what performs best.

## What works today (no platform approval needed)

- **Calendar.** Month view with a dot per post (blue: video ready, grey: idea without a video,
  orange: past its time and not posted, green: posted). Lists for the selected day, posts waiting to
  go out, coming up, and posts that need stats.
- **Add to post calendar** on the Export screen after an export. It keeps a copy of each exported
  shape (a clone on the iPhone file system, so no extra space), the project's post caption, the
  script or transcript and the length. It can also attach the video to an idea already on the calendar.
- **Captions per platform.** Each platform has its own caption. "Write a caption for each platform"
  uses the editor's `PostCopy` (AI when a key is set, on-phone hashtags otherwise).
- **Reminders.** A local notification at the post time ("Time to post: …"). Tapping it opens the post.
  It works with the phone asleep and offline because iOS delivers it, not a server.
- **Post to TikTok / Instagram / Facebook.** Copies that platform's caption, saves the best shape for it
  to Photos once, then opens the app: Instagram opens straight on the saved video, TikTok and Facebook
  open to their home screen (pick the newest video). If the app isn't installed, the share sheet opens.
  Back in Cueframe it asks "Did it post?" and marks it posted.
- **Insights.** Type in views, likes, comments, shares and saves per post. Insights shows average views
  and engagement by platform, opening line style (question, number or list, warning, personal story,
  statement), length, topic (caption hashtags) and time posted, plus top videos. With an AI key it can
  write three findings and three things to try, from titles, opening lines and numbers only.

Calendar data lives in `Documents/Posts/plans.json` on the phone. It is not in the cloud backup yet.

## What needs TikTok and Meta (Matt)

Posting without opening the other app, true scheduling while the phone is off, and stats that fill in
on their own all use the platforms' official APIs. Those need developer apps registered to Matt, and
app review. App secrets and access tokens must live on a server (a Supabase Edge Function in the
CueFrame project), never in the app or this repo.

Requirements below are from the platforms' public docs as of 2026; check each portal for current terms.

### TikTok

1. Create a developer account at developers.tiktok.com and an app (iOS, bundle id `com.mattbrown0406.cueframe`).
2. Add **Login Kit** and **Content Posting API** (Direct Post). For stats, add the **Display API** scopes
   `video.list` and `user.info.basic`.
3. Until TikTok audits the app, direct posts can only be private (visible to you). Public posting needs
   the audit, which asks for a demo video of the flow, a privacy policy and terms URL.

### Instagram and Facebook (Meta)

1. Instagram must be a **Professional** account (Business or Creator). For Facebook posting, a
   **Facebook Page**; linking the Instagram account to the Page keeps it to one login.
2. Create an app at developers.facebook.com (type Business). Add Instagram (Instagram API with
   Instagram Login or Facebook Login) and Facebook Login for Business.
3. Permissions: `instagram_business_basic`, `instagram_business_content_publish`,
   `instagram_business_manage_insights` (Instagram), and `pages_show_list`, `pages_manage_posts`,
   `pages_read_engagement`, `read_insights` (Facebook Page videos and Reels).
4. App Review for those permissions and Business Verification. While in development mode, it already
   works for accounts listed as testers on the app, which is enough for Matt's own use.
5. Instagram publishing fetches the video from a public URL, so each video has to be uploaded to
   storage first. That is the main cost: Supabase Storage beyond the free 1 GB is billed per GB.

### How it would be built once access exists

- Supabase Edge Functions: `oauth-callback` (stores tokens encrypted, per user), `publish` (posts now),
  and a `pg_cron` job every minute that publishes due posts, so a post goes out at its time with the
  phone off. `stats` refreshes views and likes daily for posted videos.
- The phone uploads the video (Wi-Fi) to a private bucket and hands the function a short-lived signed URL.
- The Post tab gets a "Connect TikTok / Instagram / Facebook" row, a "Post automatically" switch per post,
  and stats update on their own. The handoff stays as the fallback.

## Not tested yet

Nothing here has run on a real iPhone. Worth checking first: the Instagram deep link lands on the saved
video, the reminder opens the right post from a cold start, and the share sheet offers TikTok when
TikTok isn't opened directly.

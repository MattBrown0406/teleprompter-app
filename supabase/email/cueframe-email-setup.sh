#!/bin/bash
# Cueframe: loads the branded sign-in emails, the email logo and a 10 GB upload limit
# into the CueFrame Supabase project. Run it with:  bash ~/Downloads/cueframe-email-setup.sh
set -e
REF="ubbuenuirzpkdmakihrk"
API="https://api.supabase.com/v1/projects/$REF"

echo ""
echo "Paste your Supabase access token and press Return."
echo "(Make one at https://supabase.com/dashboard/account/tokens . It won't show as you paste.)"
read -rs TOKEN
echo ""
[ -z "$TOKEN" ] && { echo "No token entered. Nothing changed."; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

call() {  # method url body-file
  local code
  code=$(curl -sS -o "$WORK/out" -w "%{http_code}" -X "$1" "$2" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" ${3:+--data-binary @"$3"})
  if [ "${code:0:1}" != "2" ]; then echo "  Failed ($code): $(head -c 300 "$WORK/out")"; return 1; fi
}

echo "1/3 Loading the two email templates..."
cat > "$WORK/auth.json" <<'JSON'
{"mailer_subjects_magic_link": "Your Cueframe sign-in code", "mailer_templates_magic_link_content": "<!doctype html>\n<html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"dark light\"></head>\n<body style=\"margin:0;padding:0;background:#0F0F14;\">\n<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:#0F0F14;\">\n<tr><td align=\"center\" style=\"padding:40px 16px;\">\n<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:480px;background:#1C1C24;border-radius:20px;\">\n<tr><td style=\"padding:32px 32px 8px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;\">\n<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\"><tr>\n<td style=\"vertical-align:middle;\"><img src=\"https://ubbuenuirzpkdmakihrk.supabase.co/storage/v1/object/public/brand/cueframe-icon.png\" width=\"44\" height=\"44\" alt=\"\" style=\"display:block;border-radius:10px;border:0;\"></td>\n<td style=\"vertical-align:middle;padding-left:12px;font-size:22px;font-weight:700;color:#FFFFFF;letter-spacing:-0.3px;\">Cue<span style=\"color:#FF6B5C;\">frame</span></td>\n</tr></table>\n</td></tr>\n<tr><td style=\"padding:24px 32px 0 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;\">\n<h1 style=\"margin:0 0 10px 0;font-size:22px;line-height:28px;color:#FFFFFF;font-weight:700;\">Your sign-in code</h1>\n<p style=\"margin:0;font-size:15px;line-height:22px;color:#A6A6AD;\">Use this code to sign in and bring your projects and footage to this phone.</p>\n</td></tr>\n<tr><td align=\"center\" style=\"padding:28px 32px;\">\n<div style=\"display:inline-block;background:#29293333;background-color:#292933;border:1px solid #FF6B5C;border-radius:14px;padding:16px 28px;font-family:'SF Mono',Menlo,Consolas,monospace;font-size:34px;font-weight:700;letter-spacing:8px;color:#FF6B5C;\">{{ .Token }}</div>\n</td></tr>\n<tr><td style=\"padding:0 32px 32px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;\">\n<p style=\"margin:0 0 8px 0;font-size:13px;line-height:19px;color:#A6A6AD;\">Type this code in Cueframe under <span style=\"color:#FFFFFF;\">Edit &rsaquo; Cloud backup</span>. It expires in one hour.</p>\n<p style=\"margin:0;font-size:13px;line-height:19px;color:#6E6E76;\">Didn't ask for this? You can ignore this email. Nobody can sign in without the code.</p>\n</td></tr>\n</table>\n<p style=\"margin:20px 0 0 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;font-size:12px;color:#6E6E76;\">Cueframe &middot; record, prompt and edit</p>\n</td></tr></table>\n</body></html>", "mailer_subjects_confirmation": "Your Cueframe code", "mailer_templates_confirmation_content": "<!doctype html>\n<html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"dark light\"></head>\n<body style=\"margin:0;padding:0;background:#0F0F14;\">\n<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:#0F0F14;\">\n<tr><td align=\"center\" style=\"padding:40px 16px;\">\n<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:480px;background:#1C1C24;border-radius:20px;\">\n<tr><td style=\"padding:32px 32px 8px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;\">\n<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\"><tr>\n<td style=\"vertical-align:middle;\"><img src=\"https://ubbuenuirzpkdmakihrk.supabase.co/storage/v1/object/public/brand/cueframe-icon.png\" width=\"44\" height=\"44\" alt=\"\" style=\"display:block;border-radius:10px;border:0;\"></td>\n<td style=\"vertical-align:middle;padding-left:12px;font-size:22px;font-weight:700;color:#FFFFFF;letter-spacing:-0.3px;\">Cue<span style=\"color:#FF6B5C;\">frame</span></td>\n</tr></table>\n</td></tr>\n<tr><td style=\"padding:24px 32px 0 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;\">\n<h1 style=\"margin:0 0 10px 0;font-size:22px;line-height:28px;color:#FFFFFF;font-weight:700;\">Welcome to Cueframe</h1>\n<p style=\"margin:0;font-size:15px;line-height:22px;color:#A6A6AD;\">Use this code to finish setting up cloud backup for your projects and footage.</p>\n</td></tr>\n<tr><td align=\"center\" style=\"padding:28px 32px;\">\n<div style=\"display:inline-block;background:#29293333;background-color:#292933;border:1px solid #FF6B5C;border-radius:14px;padding:16px 28px;font-family:'SF Mono',Menlo,Consolas,monospace;font-size:34px;font-weight:700;letter-spacing:8px;color:#FF6B5C;\">{{ .Token }}</div>\n</td></tr>\n<tr><td style=\"padding:0 32px 32px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;\">\n<p style=\"margin:0 0 8px 0;font-size:13px;line-height:19px;color:#A6A6AD;\">Type this code in Cueframe under <span style=\"color:#FFFFFF;\">Edit &rsaquo; Cloud backup</span>. It expires in one hour.</p>\n<p style=\"margin:0;font-size:13px;line-height:19px;color:#6E6E76;\">Didn't ask for this? You can ignore this email. Nobody can sign in without the code.</p>\n</td></tr>\n</table>\n<p style=\"margin:20px 0 0 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;font-size:12px;color:#6E6E76;\">Cueframe &middot; record, prompt and edit</p>\n</td></tr></table>\n</body></html>"}
JSON
call PATCH "$API/config/auth" "$WORK/auth.json"
echo "    Done."

echo "2/3 Raising the upload size limit to 10 GB..."
echo '{"fileSizeLimit": 10737418240}' > "$WORK/storage.json"
call PATCH "$API/config/storage" "$WORK/storage.json" && echo "    Done." || echo "    Skipped. You can set it in Storage settings instead."

echo "3/3 Uploading the logo the emails show..."
base64 -D > "$WORK/icon.png" <<'PNG'
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
AABJRU5ErkJggg==
PNG
call GET "$API/api-keys?reveal=true" || true
SERVICE=$(osascript -l JavaScript -e 'function run(a){var k=JSON.parse(a[0]).filter(function(x){return x.name=="service_role"})[0];return k?k.api_key:""}' "$(cat "$WORK/out")")
if [ -n "$SERVICE" ]; then
  code=$(curl -sS -o "$WORK/out" -w "%{http_code}" -X POST \
    "https://$REF.supabase.co/storage/v1/object/brand/cueframe-icon.png" \
    -H "Authorization: Bearer $SERVICE" -H "apikey: $SERVICE" -H "Content-Type: image/png" \
    -H "x-upsert: true" --data-binary @"$WORK/icon.png")
  [ "${code:0:1}" = "2" ] && echo "    Done." || echo "    Logo upload failed ($code). Emails still work, just without the logo."
else
  echo "    Couldn't read the project key. Emails still work, just without the logo."
fi

echo ""
echo "All set. You can delete this file and the access token now."

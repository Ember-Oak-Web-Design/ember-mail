# Setting up Ember Mail

Three parts, in any order. Allow about 20 minutes in total.

1. **Build and open the app**
2. **Add your business email (IMAP)**
3. **Connect Google (Gmail + Calendar)**, which needs your own Google OAuth client
4. **Turn on read receipts**, which needs a free Cloudflare Worker

---

## 1. Build and open

```bash
cd ~/"Documents/Ember & Oak/Mail Client"
./scripts/build-app.sh --install   # builds and copies to ~/Applications/Ember Mail.app
open ~/Applications/"Ember Mail.app"
```

The first time you open it, macOS may say the app is from an unidentified developer. If so,
right-click the app → **Open** → **Open**.

When macOS asks whether Ember Mail can use your Keychain, choose **Always Allow**. Each rebuild changes
the app's signature, so you may be asked again after rebuilding.

## 2. Business email (IMAP / SMTP)

Find your mail host's settings. They're usually in your hosting control panel under "Email
accounts" → "Connect devices" or "Mail client configuration".

| Setting | Typical value |
|---|---|
| Incoming (IMAP) server | `mail.yourdomain.com` (port **993**, SSL/TLS) |
| Outgoing (SMTP) server | `mail.yourdomain.com` (port **465**, SSL/TLS) |
| Username | your full email address |

In Ember Mail: **Add business email** on the welcome screen, or **Settings → Accounts → + →
Business email**. Ember Mail checks the sign-in for both incoming and outgoing mail before it saves
the account.

> Ember Mail sends on port 465 (SSL/TLS). Hosts that only offer port 587 (STARTTLS) aren't supported
> yet. Most hosts (cPanel, Zoho, Fastmail, IONOS, Namecheap Private Email) offer 465.
> Microsoft 365 / Outlook.com accounts block password sign-in, so they won't work over IMAP.

## 3. Google account (Gmail + Calendar)

The app ships with the public OAuth **Client ID**. The **Client secret** lives only on the Worker, which does the token exchange and refresh, so nothing needs entering in the
app, and every Mac and Google account works the same way.

One-time setup (the Worker is deployed in step 4):

1. <https://console.cloud.google.com/> → project → enable **Gmail API** and **Google Calendar API**.
2. **Credentials → OAuth client ID → Desktop app**. Copy `Sources/EmberMail/Services/LocalConfig.example` to `LocalConfig.swift` and fill in the
   Client ID and Worker URL; copy `server/tracking-worker/wrangler.toml.example` to `wrangler.toml` and fill in the Client ID, domain and KV id.
   Both files are gitignored, so these values stay out of the public repo (they remain visible inside the shipped app, which is fine).
3. Store the secret on the Worker (never in the repo): `cd server/tracking-worker && npx wrangler secret put GOOGLE_CLIENT_SECRET`,
   then `npx wrangler deploy`.
4. **Publishing for any Gmail account:** OAuth consent screen → set the app name, logo
   (`docs/brand/ember-mail-logo.svg`), homepage, **Privacy Policy** `https://emberandoakdesign.com/legal/ember-mail/privacy`
   and **Terms** `.../terms` (pages in `docs/website/`, noindex and not in the sitemap), add `emberandoakdesign.com`
   as an authorized domain, then **Publish app**. Gmail scopes are *restricted*, so Google requires verification
   (and may ask for a security assessment) before more than 100 users can sign in without the "unverified" screen.
   Until then, the 7-day sign-out only applies while the app is in *Testing*.
5. In Ember Mail: **Settings → Accounts → + → Google account**.

## 4. Read receipts

Ember Mail adds an invisible 1×1 image to outgoing emails. A tiny Cloudflare Worker that you own
serves the image and records when it's loaded. Cloudflare's free plan is plenty.

Deploy it with [`server/tracking-worker/README.md`](../server/tracking-worker/README.md). The app needs no
setup for this: the Worker URL is built in, and there's no read-receipt secret to enter on each Mac.

How to read the results (in your **Sent** folder, next to each email's subject):
- small grey tick: sent, not read yet
- green **Read** label: the recipient opened it (**Read ×3** if several times; hover for when)
- orange **Maybe read**: only an automatic image load by Apple Mail Privacy Protection, so not proof it was read
- Every open also triggers a desktop notification (checked every minute while Ember Mail is running).
  Click it to jump to your Sent folder. You can switch these off in Settings → Read Receipts.
- Filter → "Read receipt" in any list shows only read or not-yet-read sent emails.

Each compose window has a **Read receipt** switch (on by default; change the default in Settings).
The "Ask recipient to confirm" checkbox adds a standard return-receipt request. Some recipients' mail
apps will show them a prompt; most ignore it.

## Troubleshooting
- **macOS asks for my password about the Keychain:** this happens once, the first time a new version reads your
  old saved passwords (it moves them to a store that never asks again). Enter your Mac password and choose
  **Allow** or **Always Allow**. If you click **Deny**, the app can't read your passwords that launch (accounts
  will show sign-in errors) and asks again next launch.
- **"Sign-in failed"**: check the username (usually the full address) and password. Some hosts need an
  app password when two-factor authentication is on.
- **Google says "Access blocked"**: add your address as a test user (step 3), or publish the app.
- **Google stopped working after a week**: publish the consent screen (see above), then
  Settings → Accounts → select the Google account → **Reconnect**.
- **No notifications**: System Settings → Notifications → Ember Mail → Allow.

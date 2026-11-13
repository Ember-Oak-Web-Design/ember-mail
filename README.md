<p align="center"><img src="docs/brand/ember-mail-logo.svg" width="120" alt="Ember Mail logo"></p>

# Ember Mail

A fast, native Mac email app by [Ember & Oak](https://emberandoakdesign.com). Business email (IMAP/SMTP) and Gmail side by side,
with read receipts, a built-in Google Calendar, scheduled send, reply reminders and keyboard shortcuts for everything.

Your mail goes straight between your Mac and your provider. We never see it. See the [privacy policy](https://emberandoakdesign.com/legal/ember-mail/privacy).

## Download

1. Go to the [**latest release**](../../releases/latest) and download `Ember-Mail-x.y.z.zip`.
2. Unzip it and drag **Ember Mail** into your **Applications** folder.
3. **First open only:** macOS will say it can't verify the developer. Right-click **Ember Mail** → **Open** → **Open**.
   (On newer macOS: *System Settings → Privacy & Security → Open Anyway*.)
4. Add an account: **Settings → Accounts → +**.

Requires macOS 14 or later (Apple silicon).

**Updates:** Ember Mail checks for new versions itself. When one is available a bar appears at the top of the window with
*What's new*, *Update Now*, *Later* and *Skip This Version*. Nothing installs unless you click.

## Accounts

- **Google (Gmail + Calendar):** click *Google account*, sign in in your browser and allow access.
  While the app is awaiting Google's verification you'll see an "unverified app" screen: choose *Advanced → Continue*.
- **Business / other email (IMAP):** enter your address and password. Common hosts are filled in automatically.
  Microsoft 365 and Outlook.com block password sign-in, so they aren't supported yet.

## Features

- Unified *All Inboxes*, conversation threads, swipe actions, filters (including *all unread*), multi-select (⇧-click, ⇧-drag)
- Read receipts on sent mail, with a green *Read* label and a notification on every open
- Scheduled send, drafts that autosave, reply reminders, HTML and image signatures
- Google Calendar (day / week / month) and a Today panel next to your inbox
- Customisable keyboard shortcuts, with a Gmail-style preset

## Building from source

Most people should use the download above. To build your own copy you need a Mac with the Xcode Command Line Tools, plus your own
Google OAuth client and Cloudflare Worker, because the maintainers' deployment values are not in this repository.
See [docs/SETUP.md](docs/SETUP.md), then:

```bash
cp Sources/EmberMail/Services/LocalConfig.example Sources/EmberMail/Services/LocalConfig.swift   # fill in
./scripts/build-app.sh --run
./scripts/test.sh
```

Developer notes live in [CLAUDE.md](CLAUDE.md). Releases are cut with `./scripts/release.sh X.Y.Z`.

## Legal

[Privacy Policy](https://emberandoakdesign.com/legal/ember-mail/privacy) · [Terms of Service](https://emberandoakdesign.com/legal/ember-mail/terms)

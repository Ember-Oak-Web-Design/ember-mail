# Ember Mail read-receipt Worker

A ~90-line Cloudflare Worker that serves the invisible 1×1 image Ember Mail adds to outgoing
emails, and records when it's loaded. Free tier is plenty for a small business
(100k requests/day, 1k KV writes/day ≈ 1,000 opens/day).

## Deploy (≈5 minutes)
Requires Node.js (`brew install node` or https://nodejs.org) and a free Cloudflare account.

```bash
cd server/tracking-worker
npx wrangler login                         # opens the browser
npx wrangler kv namespace create OPENS     # copy the printed id into wrangler.toml
npx wrangler secret put GOOGLE_CLIENT_SECRET   # Google sign-in (see docs/SETUP.md)
npx wrangler deploy                         # prints https://ember-receipts.<you>.workers.dev
```



Nothing to configure in the app: the Worker URL is built in and there is no read-receipt secret.
Each sent message gets its own random read key (stored on that Mac); the pixel URL only contains a SHA-256
hash of it, so recipients can't read the open log. (`SECRET` is now only needed to read pre-key messages.)

## Optional: your own domain
Recipients can see the image URL if they inspect the email. To keep it on-brand, add a route such as
`t.emberandoak.com/*` to the Worker in the Cloudflare dashboard (your domain must use Cloudflare DNS)
and use `https://t.emberandoak.com` as the Worker URL in Ember Mail.

## Privacy & accuracy notes
- Only the sending app (holding the per-message read key) can read open data. Opens auto-expire after 90 days.
- Gmail fetches images through its proxy when the recipient opens the email: reliable.
- Apple Mail Privacy Protection pre-fetches images when mail arrives, even if not read; the app
  labels those "may be automatic".
- Recipients who block images won't register opens.

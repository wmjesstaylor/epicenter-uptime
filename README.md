# epicenter-uptime

External uptime probe for the Epicenter CDN feed. Runs on GitHub
Actions (off-poseidon, off-Cloudflare-R2) so it can detect failure
modes the on-poseidon `epicenter-alert-check` script can't see by
definition — namely, "poseidon itself is dead."

## What it checks

A workflow scheduled every 5 minutes that:

1. `curl`s the public CDN feed URL (R2 object)
2. Verifies HTTP 2xx status
3. Parses the `Last-Modified` header
4. Fails if the feed is more than **15 min stale** (3 missed
   feed-builder cycles — feed-builder runs every 5 min)
5. On failure, sends a high-priority Pushover push notification
   to the operator's phone

## Why it lives here, not on poseidon

The on-poseidon `epicenter-alert-check` runs every 10 min and
catches local issues (disk, memory, service-down, log-spike). But
it's running ON poseidon — if poseidon is down, the alerter is
also down. This probe lives on a completely separate provider
(GitHub) so a poseidon outage triggers the alert.

Three independent providers in the alert pipeline:
- **DigitalOcean** (poseidon hosts the work)
- **GitHub** (probe runs here)
- **Pushover** (notification delivery)

At least two have to fail simultaneously to silence the alert.

## Setup

### 1. Pushover (~5 minutes)

1. Sign up at https://pushover.net (free trial, $5 one-time per
   platform)
2. Note your **User Key** from the dashboard (top right)
3. Create a new application: "Epicenter CDN Probe" or similar
4. Note the **API Token** for that application
5. Install the Pushover app on your phone, sign in

### 2. GitHub repo secrets (~2 minutes)

In this repo's Settings → Secrets and variables → Actions →
New repository secret, add:

- `PUSHOVER_USER_KEY` — your User Key from step 1.2
- `PUSHOVER_APP_TOKEN` — your API Token from step 1.4

If these aren't set, the workflow still runs and fails on
unhealthy feed; you'll just only get GitHub's default failure
email instead of a push.

### 3. Push and verify

```bash
cd ~/git/epicenter-uptime
git init
git remote add origin <your-github-remote>
git add -A
git commit -m "Initial probe workflow"
git branch -M main
git push -u origin main
```

After pushing:
- Visit Actions tab → "Epicenter CDN feed probe"
- Click "Run workflow" to manually trigger a test run
- Should complete in ~5-10 seconds with green status

### 4. Test the failure path

Lower the staleness threshold temporarily to force a failure:

1. Edit `.github/workflows/probe.yml`, change `MAX_STALE_SEC: '900'`
   to `MAX_STALE_SEC: '1'`
2. Commit and push
3. Manually trigger workflow
4. Confirm Pushover push lands within ~10 seconds
5. Revert the change, push again

## Tuning

- **`*/5 * * * *` cron**: every 5 min. GitHub Actions cron has
  documented imprecision — runs can be late by up to 15 min during
  platform load. For "poseidon is dead" detection, that's fine;
  alternative would be running on a paid CI tier or a self-hosted
  runner, both overkill.
- **`MAX_STALE_SEC: '900'`**: 15 min. Feed-builder runs every 5 min
  so 15 = 3 missed cycles. Loose enough to ride out one cycle
  blip without false-positive, tight enough to catch real outages.
- **Pushover `priority=1`**: high priority — bypasses Pushover
  quiet hours but doesn't require acknowledgment. Reserved
  `priority=2` for must-act-now (would also need retry/expire
  params per Pushover spec).

## What this probe does NOT cover

- Per-poller health (use `epicenter-alert-check` on poseidon)
- Database integrity (use daily `epicenter-digest-database`)
- iOS app behavior (no server-side check can verify this; rely
  on TestFlight feedback)
- DNS / SSL cert expiry (separate concern; could be added but
  most R2 + Cloudflare combos don't have user-facing certs we
  manage)

## Related

This probe is paired with on-poseidon urgent alerts
(`epicenter-alert-check` in the `epicenter-server` repo) — the
two together form the operational alerting layer:

- **On-poseidon**: fine-grained checks, can see every service +
  disk + memory, but can't see "poseidon itself is dead"
- **Off-poseidon (this)**: only sees the public-facing CDN feed,
  but THAT'S what users care about, and detects the catastrophic
  outage case

Either firing means the operator should investigate. Both firing
simultaneously means a real production incident.

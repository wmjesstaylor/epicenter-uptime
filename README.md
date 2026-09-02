# epicenter-uptime

External uptime probe for the Epicenter CDN feed. Runs on GitHub
Actions (off-poseidon, off-Cloudflare-R2) so it can detect failure
modes the on-poseidon `epicenter-alert-check` script can't see by
definition — namely, "poseidon itself is dead."

## What it checks

A workflow scheduled every 5 minutes that, for **both** feed URLs:

- the canonical custom domain `feed.seismology.rocks/30day.geojson`
  (what production clients hit since the 2026-05-28 cutover)
- the legacy R2 URL `pub-…r2.dev/30day.geojson` (still serves
  v1.9.13 and earlier)

1. `curl`s the URL
2. Verifies HTTP 2xx status
3. Parses the `Last-Modified` header
4. Fails if the feed is more than **15 min stale** (3 missed
   feed-builder cycles — feed-builder runs every 5 min)
5. On failure, sends a high-priority Pushover push notification
   to the operator's phone

Probing both means a DNS / Cloudflare-routing break on the custom
domain is caught even when the underlying R2 object is healthy —
the failure mode a legacy-URL-only probe is blind to.

## Keepalive (don't let GitHub disable the watchdog)

GitHub disables *scheduled* workflows after **60 days of no repo
commits**. This repo is otherwise dormant, so `keepalive.yml` makes
a weekly empty commit to reset that clock for all scheduled
workflows here (including itself). It's self-contained — no
third-party action on the thing that keeps the watchdog alive. If
the probe ever does get disabled, re-enable it in the Actions tab
and push any commit to re-arm the timer.

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

## Host configuration scripts (seismology-rocks/)

Beyond the probe itself, this directory holds the host-hardening scripts applied
on 2026-09-02. All are idempotent and all support `--revert`.

| Script | What it does |
|---|---|
| `setup-fail2ban.sh` | Retunes fail2ban for a distributed botnet rather than one loud host, plus `recidive` and `dbpurgeage=5w` |
| `setup-cloudflare-realip.sh` + `cloudflare-ips-refresh` | nginx `real_ip` so logs show real visitors, on a validated weekly-refreshed copy of Cloudflare's ranges |
| `setup-origin-lockdown.sh` | Restricts 80/443 to Cloudflare, so the origin cannot be reached directly |
| `setup-dns-resolvers.sh` | Replaces DigitalOcean's DNS resolvers with Cloudflare + Google |

### ⚠️ Before changing ANY droplet networking

`setup-dns-resolvers.sh` writes `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`,
because cloud-init otherwise regenerates `50-cloud-init.yaml` on every reboot and
restores the DigitalOcean resolvers.

**So DigitalOcean control-panel network changes no longer reach the droplet
automatically** — enabling IPv6, adding a floating IP, adding a VPC interface.
If you change a droplet's networking in the panel, either run `--revert` first or
re-run the script afterwards and add the new interface by hand. Applied on all
three droplets (poseidon, poseidon-staging, seismology.rocks). Pristine netplan
backups live in `/var/backups/netplan/`.

### Three traps these scripts exist to work around

All three produced a config that looked applied and was not, with no error in any
log. Each is guarded by a count assertion now — the comments in each script carry
the full detail.

1. **netplan merges nameserver lists** rather than replacing them, so a `99-*.yaml`
   drop-in leaves the old resolvers in place and first in line.
2. **systemd drop-ins append to `DNS=`**, and `99-` sorts *before* `DigitalOcean.conf`
   (strcmp: `9` < `D`). Use a `zz-` prefix; "99 means last" only holds while every
   filename is numeric.
3. **Cloudflare's published IP lists have no trailing newline**, so `while read`
   silently drops the final range. Harmless in nginx, an outage in the firewall.

The general lesson: verifying the generated artifact is not verifying the running
behaviour. Assert on running state, and count what you produced.

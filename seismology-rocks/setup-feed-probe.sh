#!/bin/bash
# Installs the Epicenter CDN feed probe on seismology.rocks. Idempotent — safe
# to re-run; it never overwrites credentials you have already filled in.
#
#   sudo ./setup-feed-probe.sh
#
# Run this on seismology.rocks (NOT poseidon — the whole point is that the probe
# lives on a different machine, so it can still speak up when poseidon is dead).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

HOST=$(hostname -s 2>/dev/null || echo unknown)
if [ "$HOST" = "poseidon" ]; then
    echo "REFUSING: this probe must not run on poseidon — it exists to detect" >&2
    echo "poseidon being down, which it cannot do from poseidon." >&2
    exit 1
fi

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
CONF=/etc/epicenter-feed-probe.env
STATE_DIR=/var/lib/epicenter-feed-probe

echo "=== installing probe to /usr/local/bin ==="
install -o root -g root -m 0755 "$SRC_DIR/epicenter-feed-probe" /usr/local/bin/epicenter-feed-probe
ls -l /usr/local/bin/epicenter-feed-probe

echo "=== state directory ==="
mkdir -p "$STATE_DIR"
chown root:root "$STATE_DIR"
chmod 0755 "$STATE_DIR"

echo "=== config at $CONF ==="
# Never clobber real credentials on a re-run.
if [ -e "$CONF" ]; then
    echo "$CONF already exists — leaving it untouched."
else
    cat > "$CONF" <<'EOF'
# Epicenter feed probe — alert channels. Configure EITHER or BOTH.
# This file holds credentials: keep it 0600 and out of git.

# --- Pushover (sub-second push; best for "act now") ---
# Same credentials as the GitHub Actions probe's repo secrets.
PUSHOVER_USER_KEY=
PUSHOVER_APP_TOKEN=

# --- Email (lands with the poseidon digests) ---
# Requires msmtp configured on this box — see the msmtp step in this script.
ALERT_EMAIL=
ALERT_FROM=info@odysseymaps.io
MSMTP_ACCOUNT=proton

# --- Tuning (defaults shown; uncomment to change) ---
# MAX_STALE_SEC=900     # 15 min = 3 missed feed-builder cycles
# REALERT_SEC=3600      # while unhealthy, re-alert at most hourly
EOF
    chown root:root "$CONF"
    chmod 0600 "$CONF"
    echo "Wrote $CONF — FILL IN at least one alert channel."
fi
ls -l "$CONF"

echo "=== msmtp (optional — only needed for email alerts) ==="
if command -v msmtp >/dev/null 2>&1; then
    echo "msmtp already installed."
    [ -e /etc/msmtprc ] && echo "/etc/msmtprc present." \
                        || echo "NOTE: /etc/msmtprc missing — copy poseidon's (same Proton account)."
else
    echo "msmtp NOT installed. For email alerts:"
    echo "    sudo apt-get install -y msmtp msmtp-mta ca-certificates"
    echo "    # then copy /etc/msmtprc from poseidon (same Proton creds), chmod 0600"
    echo "Skip this entirely if you only want Pushover."
fi

echo "=== systemd units ==="
install -o root -g root -m 0644 "$SRC_DIR/epicenter-feed-probe.service" /etc/systemd/system/
install -o root -g root -m 0644 "$SRC_DIR/epicenter-feed-probe.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now epicenter-feed-probe.timer

echo "=== timer schedule ==="
systemctl list-timers epicenter-feed-probe.timer --no-pager

echo
echo "=== one-shot test run (alerts fire only on an actual fault) ==="
systemctl start epicenter-feed-probe.service || true
journalctl -u epicenter-feed-probe.service -n 20 --no-pager

echo
echo "=== done ==="
echo "Watch it:      journalctl -u epicenter-feed-probe.service -f"
echo "Run by hand:   sudo /usr/local/bin/epicenter-feed-probe; echo \$?   # 0=healthy 1=unhealthy"
echo "Test an alert: sudo FEED_URLS=https://feed.seismology.rocks/does-not-exist \\"
echo "                    /usr/local/bin/epicenter-feed-probe"

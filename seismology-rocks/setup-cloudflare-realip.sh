#!/bin/bash
# Installs Cloudflare real_ip support for nginx on seismology.rocks, plus a
# weekly refresh of the range list. Idempotent — safe to re-run.
#
#   sudo ./setup-cloudflare-realip.sh
#
# WHAT THIS FIXES. This host sits behind Cloudflare, but nginx had no real_ip
# configuration, so the access log recorded Cloudflare's edge address as the
# client for every proxied request. Two consequences, measured 2026-09-02:
#
#   - Analytics were fiction. 291 "visitors" were Cloudflare edge nodes.
#   - Any fail2ban jail on that log would have banned CLOUDFLARE, taking the
#     blog off the internet for every reader behind that edge. This is why the
#     web jails in setup-fail2ban.sh are shipped disabled.
#
# WHY THE TRUST LIST MATTERS MORE THAN USUAL HERE. real_ip_header lets a peer
# DECLARE the client address. That is only safe because set_real_ip_from limits
# which peers are believed. It matters more on this box than on a typical origin
# because the origin is directly reachable (143.198.97.236 serves the site to
# anyone), so anyone can connect and send a forged CF-Connecting-IP. With the
# trust list correct, nginx ignores the header from non-Cloudflare peers and
# logs their real address; without it, an attacker could pick which IP address
# to have fail2ban ban — including yours.
#
# Run this BEFORE enabling any nginx fail2ban jail, and before the origin
# lockdown (which reuses the same range list).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

command -v nginx >/dev/null 2>&1 || { echo "nginx not installed" >&2; exit 1; }

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
REFRESH=/usr/local/sbin/cloudflare-ips-refresh

echo "=== installing $REFRESH ==="
install -o root -g root -m 0755 "$SRC_DIR/cloudflare-ips-refresh" "$REFRESH"

echo "=== weekly refresh timer ==="
# Cloudflare changes these ranges rarely, but "rarely" is not "never", and a
# stale list silently degrades: first it mislabels a few visitors, and after the
# lockdown lands it starts refusing real readers. Weekly is cheap insurance.
cat > /etc/systemd/system/cloudflare-ips-refresh.service <<'EOF'
[Unit]
Description=Refresh Cloudflare IP ranges (nginx real_ip, and firewall if enabled)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cloudflare-ips-refresh
EOF

cat > /etc/systemd/system/cloudflare-ips-refresh.timer <<'EOF'
[Unit]
Description=Weekly refresh of Cloudflare IP ranges

[Timer]
OnCalendar=Mon 04:17
RandomizedDelaySec=30m
# Catch up after downtime — a droplet that was off for the scheduled slot
# should not wait a week to notice a range change.
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflare-ips-refresh.timer
echo "timer enabled:"
systemctl list-timers cloudflare-ips-refresh.timer --no-pager | head -3

echo
echo "=== fetching ranges and applying real_ip now ==="
"$REFRESH" --force

echo
echo "=== verification ==="
echo "--- generated config (first 6 lines) ---"
head -6 /etc/nginx/conf.d/cloudflare-realip.conf 2>/dev/null || echo "  MISSING"
echo "--- ranges trusted ---"
echo "  v4: $(wc -l < /etc/cloudflare/ips-v4 2>/dev/null || echo 0)  v6: $(wc -l < /etc/cloudflare/ips-v6 2>/dev/null || echo 0)"
echo "--- nginx ---"
nginx -t

echo
echo "Done. Confirm real addresses are being logged — new entries should show"
echo "visitor IPs rather than Cloudflare's 104.x / 162.158.x / 172.6x.x:"
echo
echo "    sudo tail -20 /var/log/nginx/access.log | awk '{print \$1}' | sort -u"
echo
echo "Requests arriving DIRECTLY at the origin still log their own address --"
echo "that is correct, and those are exactly the ones the lockdown will remove."

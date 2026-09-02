#!/bin/bash
# Tunes fail2ban on seismology.rocks. Idempotent — safe to re-run.
#
#   sudo ./setup-fail2ban.sh
#
# WHY THIS EXISTS. fail2ban was already installed, enabled, and running here —
# and was still catching only 2.6% of the attackers. Measured 2026-09-02:
#
#     70,548  failed SSH attempts in 7 days
#      3,054  distinct source IPs
#         78  distinct IPs actually banned
#
# It was not broken. It was tuned for the wrong threat. The stock settings
# (maxretry=5 within findtime=10m, bantime=10m) assume ONE host hammering the
# door. What actually arrives is a botnet: ~3,000 IPs each trying roughly three
# times a day, every one of them staying under a 10-minute counter by design.
# And the few that did trip it were free to return ten minutes later.
#
# So the fix is not a new tool, it is a longer memory:
#
#     findtime  10m -> 1d    remember an IP long enough to see the pattern
#     maxretry    5 -> 3     three failures in a day is not a typo
#     bantime   10m -> 1w    make a ban cost something
#     + recidive             anyone banned repeatedly gets a month
#
# NOTE ON WEB JAILS. nginx jails are deliberately NOT enabled here yet. This
# host sits behind Cloudflare but nginx has no real_ip configuration, so the
# access log records CLOUDFLARE's edge IPs as the client. A jail on that log
# would ban Cloudflare and take the blog off the internet for every visitor
# behind that edge. Fix real_ip first (set_real_ip_from + CF-Connecting-IP),
# THEN add web jails. See setup-origin-lockdown.sh.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

command -v fail2ban-server >/dev/null 2>&1 || {
    echo "fail2ban is not installed. apt-get install -y fail2ban" >&2; exit 1; }

JAIL=/etc/fail2ban/jail.local
SERVER_CONF=/etc/fail2ban/fail2ban.local
STAMP=$(date -u '+%Y%m%d-%H%M%S')

# ── Make the long bantimes real ───────────────────────────────────────
# fail2ban persists active bans in sqlite and re-applies them on restart, but
# only back as far as dbpurgeage — which ships as 1d. Raising bantime to 1w and
# recidive to 4w WITHOUT raising this buys much less than it appears to: the
# first restart more than a day later drops every ban older than 24h, and
# fail2ban restarts on package upgrade, so this is routine, not hypothetical.
# Keep it comfortably above the longest bantime in jail.local (4w).
cat > "$SERVER_CONF" <<'EOF'
# Managed by setup-fail2ban.sh (epicenter-uptime repo).
[Definition]
# Must exceed the longest bantime (recidive, 4w) or long bans do not survive a
# fail2ban restart.
dbpurgeage = 5w
EOF
chown root:root "$SERVER_CONF"
chmod 0644 "$SERVER_CONF"
echo "wrote $SERVER_CONF (dbpurgeage = 5w)"

# Keep a copy of whatever is there now. Restoring is then a `cp`, not an
# archaeology exercise, and this script has already proven it changes behaviour
# that someone might want back in a hurry.
if [ -e "$JAIL" ]; then
    cp -a "$JAIL" "${JAIL}.bak-${STAMP}"
    echo "backed up existing jail.local -> ${JAIL}.bak-${STAMP}"
fi

cat > "$JAIL" <<'EOF'
# Managed by setup-fail2ban.sh (epicenter-uptime repo). Re-running the script
# overwrites this file; the previous copy is kept as jail.local.bak-<stamp>.

[DEFAULT]
# Never ban the loopback. Deliberately NOT adding a home/office IP: this box is
# key-only (PasswordAuthentication no), so a legitimate operator does not
# generate auth failures, and a hardcoded "safe" IP is a standing hole that
# outlives whoever added it.
#
# NOTE ON LOCKOUT RECOVERY — this used to say "use the DigitalOcean web
# console, it is out-of-band". BOTH HALVES WERE WRONG, checked 2026-09-02:
# the Droplet Console is NOT out-of-band (it is SSH to port 22 as root, set up
# by droplet-agent), and it cannot work here because every box sets
# PermitRootLogin no — since 2026-04-29 on poseidon, 2026-05-30 on staging.
# The genuinely out-of-band path is the DO *Recovery* Console, which needs a
# root password you can actually produce. See the note in
# setup-origin-lockdown.sh.
ignoreip = 127.0.0.1/8 ::1

# The stock 10m/10m/5 catches a single loud host. It does not catch a botnet
# pacing itself at three attempts a day per IP, which is what actually arrives
# here. A one-day window is what makes low-and-slow visible at all.
findtime = 1d
maxretry = 3
bantime  = 1w

# Ban at the packet level rather than via hosts.deny.
banaction = iptables-multiport

[sshd]
enabled  = true
port     = 22
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3

# Repeat offenders — anyone fail2ban has already banned 3 times gets a month.
# Reads fail2ban's OWN log, so it sees across every other jail.
[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
bantime  = 4w
findtime = 1w
maxretry = 3

# --- Web jails: intentionally left disabled ---------------------------------
# Do NOT enable these until nginx real_ip is configured. Without it the access
# log shows Cloudflare's IPs, and banning those bans your readers.
#
# [nginx-http-auth]
# enabled = true
# [nginx-botsearch]
# enabled = true
EOF

chown root:root "$JAIL"
chmod 0644 "$JAIL"
echo "wrote $JAIL"

# Validate BEFORE restarting. A bad jail file takes fail2ban down entirely,
# which would leave the box less protected than before this script ran.
echo "=== validating configuration ==="
if ! fail2ban-client -t; then
    echo "CONFIG TEST FAILED — restoring previous jail.local and leaving fail2ban alone" >&2
    if [ -e "${JAIL}.bak-${STAMP}" ]; then
        cp -a "${JAIL}.bak-${STAMP}" "$JAIL"
        echo "restored ${JAIL}.bak-${STAMP}" >&2
    else
        rm -f "$JAIL"
        echo "removed the jail.local this script created" >&2
    fi
    exit 1
fi

echo "=== restarting fail2ban ==="
systemctl restart fail2ban
sleep 3
systemctl is-active fail2ban

echo
echo "=== jail status ==="
fail2ban-client status
for j in sshd recidive; do
    echo "--- $j ---"
    fail2ban-client status "$j" 2>/dev/null || echo "  (jail not running)"
done

echo
echo "Done. Watch it work with:"
echo "    sudo grep ' Ban ' /var/log/fail2ban.log | tail -20"
echo "    sudo fail2ban-client status sshd"
echo
echo "Expect the ban count to rise sharply — the 1-day findtime now sees IPs"
echo "that the 10-minute window was structurally unable to catch."

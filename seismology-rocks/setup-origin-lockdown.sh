#!/bin/bash
# Restricts ports 80/443 on seismology.rocks to Cloudflare's ranges, so the
# origin can only be reached through Cloudflare. Idempotent — safe to re-run.
#
#   sudo ./setup-origin-lockdown.sh            # apply
#   sudo ./setup-origin-lockdown.sh --revert   # undo, restore previous rules
#
# WHY. Measured from outside on 2026-09-02: https://143.198.97.236/ returns the
# blog, with a spoofed Host header, to anyone who asks. And it is not
# theoretical — 2,635 of 3,775 logged requests (70%) already arrived directly at
# the origin rather than through Cloudflare, one single source accounting for
# 1,945 of them. Every one of those bypassed the WAF, the rate limiting, the
# bot rules and the caching. Cloudflare was, in practice, optional.
#
# THIS IS THE RISKIEST CHANGE IN THIS REPO. A wrong or stale range list here
# does not degrade the site, it removes it. Hence: the list is fetched and
# validated by cloudflare-ips-refresh (never hand-edited), the previous firewall
# state is saved before anything changes, and the script verifies the site AND
# the certificate-renewal path through Cloudflare afterwards — rolling back
# automatically if either fails. It should be impossible for a successful run of
# this script to leave the blog unreachable.
#
# SSH IS DELIBERATELY UNTOUCHED. Port 22 keeps its existing rules. Cloudflare
# does not proxy SSH, so restricting it here would lock you out of the box. The
# DigitalOcean web console is out-of-band and works regardless.
#
# CERTIFICATE RENEWAL. acme.sh renews via webroot HTTP-01 at
# /var/www/ghost/system/nginx-root (next due 2026-10-29). Let's Encrypt
# validates by fetching http://seismology.rocks/.well-known/acme-challenge/...,
# which resolves to Cloudflare and therefore reaches the origin from a
# Cloudflare address — allowed. This holds ONLY while the DNS record stays
# proxied (orange cloud). If anyone ever greys it out, renewal breaks silently
# and you find out when the cert expires. The post-flight check below exercises
# this exact path rather than trusting the reasoning.
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

SITE_URL=https://seismology.rocks/
ACME_WEBROOT=/var/www/ghost/system/nginx-root
V4=/etc/cloudflare/ips-v4
V6=/etc/cloudflare/ips-v6
MARKER=/etc/cloudflare/lockdown-enabled
BACKUP_DIR=/var/backups/ufw
STAMP=$(date -u '+%Y%m%d-%H%M%S')

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# ── backup / restore ──────────────────────────────────────────────────
backup_rules() {
    mkdir -p "$BACKUP_DIR"
    cp -a /etc/ufw/user.rules  "$BACKUP_DIR/user.rules.$STAMP"  2>/dev/null || true
    cp -a /etc/ufw/user6.rules "$BACKUP_DIR/user6.rules.$STAMP" 2>/dev/null || true
    echo "$STAMP" > "$BACKUP_DIR/latest"
    log "firewall rules backed up to $BACKUP_DIR/*.$STAMP"
}

restore_rules() {
    local stamp="$1"
    [ -f "$BACKUP_DIR/user.rules.$stamp" ] || { log "no backup $stamp to restore"; return 1; }
    cp -a "$BACKUP_DIR/user.rules.$stamp"  /etc/ufw/user.rules
    [ -f "$BACKUP_DIR/user6.rules.$stamp" ] && cp -a "$BACKUP_DIR/user6.rules.$stamp" /etc/ufw/user6.rules
    ufw --force reload >/dev/null 2>&1
    log "restored firewall rules from $stamp"
}

# ── revert mode ───────────────────────────────────────────────────────
if [ "${1:-}" = "--revert" ]; then
    LATEST=$(cat "$BACKUP_DIR/latest" 2>/dev/null || true)
    [ -n "$LATEST" ] || { echo "no backup recorded in $BACKUP_DIR/latest" >&2; exit 1; }
    restore_rules "$LATEST" || exit 1
    rm -f "$MARKER"
    log "lockdown reverted; origin is directly reachable again"
    ufw status verbose | head -20
    exit 0
fi

# ── preconditions ─────────────────────────────────────────────────────
command -v ufw >/dev/null 2>&1 || { echo "ufw not installed" >&2; exit 1; }
systemctl is-active --quiet ufw || { echo "ufw is not active — refusing to edit rules" >&2; exit 1; }

# The range list must have been produced by the validated fetcher. Refusing to
# run without it is the point: a hand-typed list is exactly how this goes wrong.
for f in "$V4" "$V6"; do
    [ -s "$f" ] || { echo "missing $f — run setup-cloudflare-realip.sh first" >&2; exit 1; }
done
V4_COUNT=$(grep -c . "$V4"); V6_COUNT=$(grep -c . "$V6")
[ "$V4_COUNT" -ge 10 ] || { echo "only $V4_COUNT IPv4 ranges — refusing (list looks wrong)" >&2; exit 1; }
log "using $V4_COUNT IPv4 and $V6_COUNT IPv6 Cloudflare ranges"

# ── baseline: is the site healthy BEFORE we touch anything? ───────────
# If it is already broken, a post-flight failure would be blamed on this script
# and trigger a pointless rollback.
baseline=$(curl -4 -sS --max-time 20 -o /dev/null -w '%{http_code}' "$SITE_URL" 2>/dev/null || echo 000)
case "$baseline" in
    2*|3*) log "baseline: site returns HTTP $baseline through Cloudflare" ;;
    *) echo "baseline check FAILED (HTTP $baseline) — the site is not healthy before the change; fix that first" >&2; exit 1 ;;
esac

backup_rules

# ── apply ─────────────────────────────────────────────────────────────
# ADD-ONLY, NEVER PRUNE. When Cloudflare's list changes, this adds the new
# ranges and leaves any superseded ones allowed. That is deliberate. The two
# failure modes are not symmetric: keeping a decommissioned Cloudflare range
# allowed is a slightly wider door, while a bug in prune logic deleting a LIVE
# range takes the blog down for everyone behind it. Given the list has been
# stable for years and this runs unattended on a weekly timer, the safe
# asymmetry wins. Audit occasionally with:
#     sudo ufw status | grep cloudflare
log "adding allow rules for Cloudflare ranges on 80,443"
while IFS= read -r cidr || [ -n "$cidr" ]; do
    cidr="${cidr%$'\r'}"; [ -z "$cidr" ] && continue
    ufw allow from "$cidr" to any port 80,443 proto tcp comment 'cloudflare' >/dev/null
done < "$V4"

if grep -qi '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
    while IFS= read -r cidr || [ -n "$cidr" ]; do
        cidr="${cidr%$'\r'}"; [ -z "$cidr" ] && continue
        ufw allow from "$cidr" to any port 80,443 proto tcp comment 'cloudflare' >/dev/null
    done < "$V6"
fi

# Assert every range actually became a rule BEFORE removing the world-open ones.
# Ordering is the whole point: verify the replacement is complete while the old
# rule is still in place, so a shortfall costs nothing. The same trailing-newline
# bug that dropped two ranges from the nginx trust list would, here, have
# firewalled off live Cloudflare edges — a partial outage visible only to
# readers routed through them.
CF_RULES=$(ufw status 2>/dev/null | grep -c 'cloudflare')
EXPECTED=$V4_COUNT
grep -qi '^IPV6=yes' /etc/default/ufw 2>/dev/null && EXPECTED=$(( V4_COUNT + V6_COUNT ))
if [ "$CF_RULES" -lt "$EXPECTED" ]; then
    log "only $CF_RULES Cloudflare rules present, expected $EXPECTED — NOT removing world-open rules"
    restore_rules "$STAMP"
    exit 1
fi
log "verified $CF_RULES Cloudflare allow rules in place (expected $EXPECTED)"

# Now remove the rules that let the whole internet in on 80/443. Deleting by
# number, highest first, because every deletion renumbers what follows.
#
# SSH is explicitly excluded from this sweep. Deleting the wrong line here is
# the difference between "the blog is behind Cloudflare" and "nobody can log in
# to fix it".
log "removing world-open rules on 80/443"
mapfile -t TO_DELETE < <(
    ufw status numbered 2>/dev/null | awk '
        /^\[/ {
            line = $0
            # The rule NUMBER must come from the bracket, not from $1: ufw pads
            # single digits ("[ 1]"), so awk splits $1 as "[" and stripping
            # non-digits yields an empty string. That silently deletes nothing
            # for rules 1-9 and would have made this script a no-op on exactly
            # the table it was written for. Verified against the real output.
            num = line
            sub(/^\[[ ]*/, "", num)
            sub(/\].*$/, "", num)
            if (num !~ /^[0-9]+$/) next

            # The "To" column is everything before the action verb. Match only
            # against that, so a source address that happens to contain "22"
            # (the Cloudflare range 103.22.200.0/22 does) never looks like SSH.
            # NOTE: no apostrophes in this awk program - it is single-quoted,
            # and one contraction here already broke the whole script once.
            to = line
            sub(/^\[[^]]*\][ ]*/, "", to)
            sub(/[ ]+(ALLOW|DENY|LIMIT|REJECT).*$/, "", to)

            # Never touch SSH — deleting the wrong line here is the difference
            # between "the blog is behind Cloudflare" and "nobody can log in".
            if (to ~ /(^|[^0-9])22([^0-9]|$)/ || to ~ /OpenSSH/) next
            # Only rules open to the world.
            if (line !~ /Anywhere/) next
            # Only web ports / the nginx app profiles.
            if (to ~ /(^|[^0-9])(80|443)([^0-9]|$)/ || to ~ /Nginx/) print num
        }' | sort -rn
)

if [ "${#TO_DELETE[@]}" -eq 0 ]; then
    log "no world-open web rules found (already locked down?)"
else
    for n in "${TO_DELETE[@]}"; do
        log "  deleting rule #$n"
        ufw --force delete "$n" >/dev/null
    done
fi

ufw --force reload >/dev/null 2>&1
log "rules applied"

# ── post-flight: prove the site and the ACME path still work ──────────
# Give the reload a moment; then test through Cloudflare, which is now the only
# way in. Any failure rolls back automatically.
sleep 3
FAIL=""

site=$(curl -4 -sS --max-time 25 -o /dev/null -w '%{http_code}' "$SITE_URL" 2>/dev/null || echo 000)
case "$site" in
    2*|3*) log "post-flight: site OK through Cloudflare (HTTP $site)" ;;
    *) FAIL="site returned HTTP $site through Cloudflare" ;;
esac

# Exercise the real certificate-renewal path rather than reasoning about it: put
# a token in the ACME webroot and fetch it over plain HTTP through Cloudflare,
# exactly as Let's Encrypt will in October.
if [ -z "$FAIL" ] && [ -d "$ACME_WEBROOT" ]; then
    CHAL_DIR="$ACME_WEBROOT/.well-known/acme-challenge"
    mkdir -p "$CHAL_DIR"
    TOKEN="lockdown-selftest-$STAMP"
    echo "$TOKEN" > "$CHAL_DIR/$TOKEN"
    chmod 0644 "$CHAL_DIR/$TOKEN"
    got=$(curl -4 -sSL --max-time 25 "http://seismology.rocks/.well-known/acme-challenge/$TOKEN" 2>/dev/null || true)
    rm -f "$CHAL_DIR/$TOKEN"
    if [ "$got" = "$TOKEN" ]; then
        log "post-flight: ACME HTTP-01 path OK through Cloudflare — renewal will work"
    else
        FAIL="ACME challenge path is not reachable through Cloudflare (cert renewal would fail in October)"
    fi
elif [ -z "$FAIL" ]; then
    log "WARN: $ACME_WEBROOT not found — could not verify the renewal path"
fi

if [ -n "$FAIL" ]; then
    log "POST-FLIGHT FAILED: $FAIL"
    restore_rules "$STAMP"
    log "rolled back — origin is reachable directly again, nothing lost"
    exit 1
fi

# Only now record that lockdown is on, so weekly range refreshes keep the
# firewall in step. Written last: a run that rolled back must not leave this
# behind, or a later refresh would re-apply rules nobody verified.
mkdir -p /etc/cloudflare
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$MARKER"

# Install ourselves as the sync tool the weekly range refresh calls. Same code
# path, so a range change gets the same backup, the same post-flight checks and
# the same automatic rollback as a manual run — an unattended timer is exactly
# where you want those guarantees, not a stripped-down variant of them.
install -o root -g root -m 0755 "$0" /usr/local/sbin/cloudflare-firewall-sync
log "installed /usr/local/sbin/cloudflare-firewall-sync (used by the weekly refresh)"

echo
log "LOCKDOWN ACTIVE"
ufw status verbose | head -8
echo
echo "Verify from OFF this box that the origin is now closed:"
echo "    curl -m 10 -k https://143.198.97.236/     # should hang or refuse"
echo "    curl -m 10 https://seismology.rocks/      # should still work"
echo
echo "Undo at any time:"
echo "    sudo $0 --revert"

#!/bin/bash
# Replaces DigitalOcean's DNS resolvers with Cloudflare + Google on this host.
# Idempotent — safe to re-run. Works on any of the three droplets.
#
#   sudo ./setup-dns-resolvers.sh            # apply
#   sudo ./setup-dns-resolvers.sh --revert   # restore DO resolvers
#
# WHY. This is the root cause of the 2026-09-02 CDN-probe false alarm, not a
# tidy-up. DigitalOcean's resolvers (67.207.67.2/.3) intermittently mishandle
# EDNS0, so systemd-resolved downgrades them UDP+EDNS0 -> UDP -> TCP. Measured
# on seismology.rocks: 199 downgrades across nine months of journal, on EVERY
# day of the fortnight before the incident, and mid-downgrade when the probe
# tripped. In TCP mode a lookup can stall for many seconds and then fail, which
# is what "curl failed contacting <url>" turned out to mean.
#
# It is NOT confined to one box. poseidon and poseidon-staging use the same two
# resolvers and show the same downgrades — and poseidon polls USGS, EMSC,
# GeoNet, JMA and MMD, pushes APNs and uploads the feed. A DNS stall there is a
# missed poll or a late alert, not a spurious notification.
#
# ── WHY THIS EDITS 50-cloud-init.yaml INSTEAD OF ADDING A DROP-IN ────
# The obvious approach — a 99-*.yaml drop-in overriding nameservers — DOES NOT
# WORK, and fails in the worst way: silently, while appearing to succeed.
# netplan MERGES nameserver lists rather than replacing them. Verified against
# a throwaway root before shipping:
#
#     10-netplan-eth0.network: DNS=67.207.67.2 DNS=67.207.67.3 \
#                              DNS=1.1.1.1 DNS=1.0.0.1 DNS=8.8.8.8 DNS=8.8.4.4
#
# Both resolvers we are trying to remove are still there, first in the list, and
# systemd-resolved rotates onto whichever answers. The drop-in would have looked
# clean in every log while changing nothing about the failure being fixed.
#
# So the per-link nameservers are edited in place, and cloud-init's network
# regeneration is disabled — exactly as the header of 50-cloud-init.yaml itself
# instructs — because otherwise a reboot silently restores the DO resolvers.
#
# TRADE-OFF, STATED PLAINLY: with cloud-init network config disabled, changes
# made in the DigitalOcean control panel (enabling IPv6, adding a VPC interface,
# a floating IP) will no longer propagate into netplan automatically. On these
# long-lived, statically-addressed droplets that is a fair price; if you ever
# change a droplet's networking in the panel, re-run this script afterwards or
# revert it first.
#
# SSH IS NOT AT RISK. Even total DNS failure would not lock you out — sessions
# reach these boxes by IP. The verification below still auto-reverts on failure.
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

NETPLAN=/etc/netplan/50-cloud-init.yaml
CLOUD_INIT_DISABLE=/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
RESOLVED_DROPIN=/etc/systemd/resolved.conf.d/99-dns-resolvers.conf
BACKUP_DIR=/var/backups/netplan
STAMP=$(date -u '+%Y%m%d-%H%M%S')

# Cloudflare first, Google second — two independent operators, so an outage at
# one does not take DNS with it. Deliberately WITHOUT the DO resolvers: leaving
# them in the list lets systemd-resolved rotate back onto the servers this
# script exists to stop using. That is not hypothetical; see the merge note.
RESOLVERS="1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4"
DO_RESOLVER_PATTERN='67\.207\.67\.'

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

apply_config() {
    netplan generate || return 1
    netplan apply     || return 1
    systemctl restart systemd-resolved || return 1
    sleep 2
    return 0
}

# Resolution must work for names we actually depend on, not just one lucky
# lookup. Several names, several attempts: a resolver that answers once and
# stalls on the next is precisely the failure being fixed.
verify_resolution() {
    local names="feed.seismology.rocks seismology.rocks earthquake.usgs.gov www.cloudflare.com"
    local n fails=0 i
    for n in $names; do
        for i in 1 2 3; do
            getent hosts "$n" >/dev/null 2>&1 || fails=$((fails + 1))
        done
    done
    [ "$fails" -eq 0 ] || { log "resolution check FAILED ($fails failures)"; return 1; }
    log "resolution check OK (12/12 lookups)"
    return 0
}

restore_backup() {
    local stamp="$1"
    [ -f "$BACKUP_DIR/50-cloud-init.yaml.$stamp" ] || { log "no backup $stamp"; return 1; }
    cp -a "$BACKUP_DIR/50-cloud-init.yaml.$stamp" "$NETPLAN"
    chmod 0600 "$NETPLAN" 2>/dev/null || true
    rm -f "$CLOUD_INIT_DISABLE" "$RESOLVED_DROPIN"
    apply_config
    log "restored $NETPLAN from $stamp and re-enabled cloud-init networking"
}

# ── revert ────────────────────────────────────────────────────────────
if [ "${1:-}" = "--revert" ]; then
    LATEST=$(cat "$BACKUP_DIR/latest" 2>/dev/null || true)
    [ -n "$LATEST" ] || { echo "no backup recorded in $BACKUP_DIR/latest" >&2; exit 1; }
    restore_backup "$LATEST" || exit 1
    verify_resolution
    resolvectl status 2>/dev/null | grep -E "Current DNS Server|DNS Servers" | head -4
    exit 0
fi

command -v netplan  >/dev/null 2>&1 || { echo "netplan not found" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "python3 + PyYAML required" >&2; exit 1; }
[ -f "$NETPLAN" ] || { echo "$NETPLAN not found" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
cp -a "$NETPLAN" "$BACKUP_DIR/50-cloud-init.yaml.$STAMP"
echo "$STAMP" > "$BACKUP_DIR/latest"
log "backed up $NETPLAN -> $BACKUP_DIR/50-cloud-init.yaml.$STAMP"

# Edit with a YAML parser, not sed. The file has nested per-interface blocks and
# the indentation is load-bearing; a regex that works on one droplet will not
# necessarily work on the next.
log "rewriting nameservers for every interface"
RESOLVERS="$RESOLVERS" NETPLAN="$NETPLAN" python3 <<'PY'
import os, yaml

path = os.environ["NETPLAN"]
resolvers = os.environ["RESOLVERS"].split()

with open(path) as fh:
    cfg = yaml.safe_load(fh)

net = cfg.get("network", {})
changed = []
for family in ("ethernets", "bonds", "vlans", "bridges"):
    for name, dev in (net.get(family) or {}).items():
        ns = dev.setdefault("nameservers", {})
        ns["addresses"] = list(resolvers)
        # Preserve an existing search list; absent means none, not "delete".
        ns.setdefault("search", [])
        changed.append(name)

with open(path, "w") as fh:
    fh.write("# Rewritten by setup-dns-resolvers.sh (epicenter-uptime repo).\n")
    fh.write("# cloud-init network regeneration is disabled so this survives reboot;\n")
    fh.write("# see /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg.\n")
    fh.write("# Original saved under /var/backups/netplan/.\n")
    yaml.safe_dump(cfg, fh, default_flow_style=False, sort_keys=False)

print("  interfaces updated: " + ", ".join(changed))
PY
if [ $? -ne 0 ]; then
    log "YAML rewrite failed — restoring"
    restore_backup "$STAMP"
    exit 1
fi
chmod 0600 "$NETPLAN"

# Stop cloud-init putting the DO resolvers back on the next boot. The header of
# 50-cloud-init.yaml documents this exact file as the supported way to do it.
log "disabling cloud-init network regeneration"
mkdir -p "$(dirname "$CLOUD_INIT_DISABLE")"
echo "network: {config: disabled}" > "$CLOUD_INIT_DISABLE"

# Global resolved config too, so nothing falls back to a resolver we rejected.
log "writing $RESOLVED_DROPIN"
mkdir -p "$(dirname "$RESOLVED_DROPIN")"
{
    echo "# Managed by setup-dns-resolvers.sh (epicenter-uptime repo)."
    echo "# Sorts after DigitalOcean.conf, so these values win."
    echo "[Resolve]"
    echo "DNS=$RESOLVERS"
    echo "FallbackDNS="
} > "$RESOLVED_DROPIN"
chmod 0644 "$RESOLVED_DROPIN"

# ── generate, then ASSERT before applying ─────────────────────────────
# The whole reason this script is not a drop-in is that netplan silently merged
# the old servers back in. So check the generated output for them explicitly,
# while the running config is still untouched and a failure costs nothing.
log "generating network config"
if ! netplan generate; then
    log "netplan generate FAILED — restoring"
    restore_backup "$STAMP"
    exit 1
fi

LEFTOVER=$(grep -h "^DNS=" /run/systemd/network/*.network 2>/dev/null | grep -c "$DO_RESOLVER_PATTERN" || true)
if [ "${LEFTOVER:-0}" -ne 0 ]; then
    log "ASSERTION FAILED: $LEFTOVER DigitalOcean resolver entries survived into the generated config"
    grep -h "^DNS=" /run/systemd/network/*.network 2>/dev/null | sort -u | sed 's/^/    /'
    restore_backup "$STAMP"
    exit 1
fi
log "assertion OK: no DigitalOcean resolvers in the generated config"

log "applying"
if ! apply_config; then
    log "APPLY FAILED — restoring"
    restore_backup "$STAMP"
    exit 1
fi

if ! verify_resolution; then
    log "REVERTING to DigitalOcean resolvers"
    restore_backup "$STAMP"
    verify_resolution && log "reverted and resolving again"
    exit 1
fi

echo
log "DONE — resolvers now:"
resolvectl status 2>/dev/null | grep -E "Current DNS Server|DNS Servers" | sed 's/^/  /' | head -6
echo
echo "Confirm the EDNS0 downgrades stop. These were appearing daily; there"
echo "should be no new ones from here on:"
echo
echo "    journalctl -u systemd-resolved --since today | grep 'degraded feature set'"
echo
echo "Revert at any time:  sudo $0 --revert"

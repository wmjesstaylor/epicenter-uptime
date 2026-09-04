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
# ⛔ DO NOT RUN THIS ON UBUNTU 24.04. Verified the hard way on 2026-09-04.
#
# Pointing systemd 255 at Cloudflare/Google resolvers makes systemd-resolved
# core-dump repeatedly:
#
#   Assertion 's->read_packet->family == AF_INET6' failed
#     at src/resolve/resolved-dns-stream.c:399, function on_stream_io(). Aborting.
#
# Measured 38h after applying it: 13 crashes on poseidon, 19 on poseidon-staging,
# ZERO before the change on either, and zero ever on seismology (22.04, journal
# back to December). Rate ~1/hour and rising. It cost a real USGS poll — the
# poller failed at 2026-09-03 01:55:10, ten seconds after a crash at 01:55:00.
# systemd 255.4-1ubuntu8.17 is the newest Ubuntu ships; no update fixes it.
#
# Both 24.04 boxes were reverted with --revert on 2026-09-04. The change remains
# on seismology (22.04), where the fault it fixes is severe (195 TCP escalations,
# a 13-second stall that paged) and the crash does not occur.
#
# Check the OS before running:  . /etc/os-release; echo "$VERSION_ID"
#
# The wider lesson: applying this fleet-wide "for consistency" traded a
# theoretical fault on the 24.04 boxes (5 downgrades, ZERO app-level DNS
# failures in 14 days) for a real, accelerating one. The fleet is not uniform;
# decide per box on that box's evidence.
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
# NAME MATTERS. systemd applies drop-ins in strcmp order, and '9' (0x39) sorts
# BEFORE 'D' (0x44) — so a 99-*.conf is applied BEFORE DigitalOcean.conf, which
# then re-adds its servers after ours. That is exactly what happened on the
# first attempt here: the global scope came back as
#     1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 67.207.67.2 67.207.67.3
# The conventional "99 means last" habit is wrong once a filename starts with a
# letter. 'zz-' sorts after any capitalised vendor file.
RESOLVED_DROPIN=/etc/systemd/resolved.conf.d/zz-dns-resolvers.conf
# Older name, from before the sort-order bug was understood. Removed on sight so
# a re-run does not leave a stale file contributing to the merged config.
RESOLVED_DROPIN_OLD=/etc/systemd/resolved.conf.d/99-dns-resolvers.conf
MANAGED_MARKER="Rewritten by setup-dns-resolvers.sh"
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

# Check what resolved is ACTUALLY using, across every scope including global.
# The generated-config assertion above covers the per-link servers but says
# nothing about resolved.conf.d — and the first run here passed that assertion
# while the global scope still listed both DO resolvers. Assert on the running
# state, because that is the thing that answers queries.
verify_no_do_resolvers() {
    local found
    found=$(resolvectl status 2>/dev/null | grep -c "$DO_RESOLVER_PATTERN" || true)
    if [ "${found:-0}" -ne 0 ]; then
        log "FAILED: DigitalOcean resolvers still present in the running config"
        resolvectl status 2>/dev/null | grep -E "Current DNS Server|DNS Servers" | sed 's/^/    /'
        return 1
    fi
    log "running config OK: no DigitalOcean resolvers in any scope"
    return 0
}

restore_backup() {
    local stamp="$1"
    [ -f "$BACKUP_DIR/50-cloud-init.yaml.$stamp" ] || { log "no backup $stamp"; return 1; }
    cp -a "$BACKUP_DIR/50-cloud-init.yaml.$stamp" "$NETPLAN"
    chmod 0600 "$NETPLAN" 2>/dev/null || true
    rm -f "$CLOUD_INIT_DISABLE" "$RESOLVED_DROPIN" "$RESOLVED_DROPIN_OLD"
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

# ── Refuse on the OS where this is known to break ─────────────────────
# A comment in a header is not a guard. This script was applied fleet-wide once
# and broke two production boxes; the next person reaching for it will be
# skim-reading, so make the script itself say no.
OS_VERSION=$( . /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}" )
if [ "$OS_VERSION" = "24.04" ] && [ "${ALLOW_UNSAFE_24_04:-}" != "yes" ]; then
    cat >&2 <<'REFUSE'
REFUSING: this host is Ubuntu 24.04.

Pointing systemd 255 at Cloudflare/Google resolvers makes systemd-resolved
core-dump repeatedly (AF_INET6 assertion in resolved-dns-stream.c). Measured
2026-09-04: 13 crashes on poseidon, 19 on poseidon-staging, zero before the
change, zero ever on 22.04. It cost a real USGS poll. No Ubuntu update fixes it.

Both 24.04 boxes were reverted. If you are re-testing because a newer systemd
may have fixed it, check the version first and then:

    ALLOW_UNSAFE_24_04=yes sudo ./setup-dns-resolvers.sh

and watch for the assertion:

    journalctl -u systemd-resolved -f | grep Assertion
REFUSE
    exit 1
fi

command -v netplan  >/dev/null 2>&1 || { echo "netplan not found" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "python3 + PyYAML required" >&2; exit 1; }
[ -f "$NETPLAN" ] || { echo "$NETPLAN not found" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"

# NEVER back up a file this script already rewrote. On the second run here it
# did exactly that, so "latest" pointed at the MODIFIED config and --revert
# would have restored our own changes as if they were the original — the
# DigitalOcean resolvers would have been unrecoverable from backups.
#
# A backup you cannot roll back to is worse than none: it reports safety it does
# not provide. So: the pristine backup is the newest one WITHOUT our marker, and
# a re-run keeps pointing at it rather than burying it under fresh copies.
if grep -q "$MANAGED_MARKER" "$NETPLAN" 2>/dev/null; then
    PRISTINE=$(
        ls -1t "$BACKUP_DIR"/50-cloud-init.yaml.* 2>/dev/null | while IFS= read -r f; do
            grep -q "$MANAGED_MARKER" "$f" 2>/dev/null || { echo "$f"; break; }
        done
    )
    if [ -n "$PRISTINE" ]; then
        STAMP="${PRISTINE##*.}"
        echo "$STAMP" > "$BACKUP_DIR/latest"
        log "already managed by this script; pristine backup retained: $STAMP"
    else
        log "WARN already managed but no pristine backup found — revert will not restore DO resolvers"
    fi
else
    cp -a "$NETPLAN" "$BACKUP_DIR/50-cloud-init.yaml.$STAMP"
    echo "$STAMP" > "$BACKUP_DIR/latest"
    log "backed up $NETPLAN -> $BACKUP_DIR/50-cloud-init.yaml.$STAMP"
fi

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
rm -f "$RESOLVED_DROPIN_OLD"
mkdir -p "$(dirname "$RESOLVED_DROPIN")"
{
    echo "# Managed by setup-dns-resolvers.sh (epicenter-uptime repo)."
    echo "# Named zz- so it sorts AFTER DigitalOcean.conf (strcmp: 9 < D)."
    echo "#"
    echo "# The bare 'DNS=' below is NOT redundant. systemd drop-ins APPEND to"
    echo "# list-valued settings; assigning the empty string is the documented way"
    echo "# to reset the list first. Without it the global scope ends up as:"
    echo "#     DNS Servers: 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 67.207.67.2 67.207.67.3"
    echo "# which is what happened on the first run here — the DO resolvers survive"
    echo "# as a fallback path, in a file whose whole purpose is removing them."
    echo "# Same silent-merge trap as netplan nameservers; different subsystem."
    echo "[Resolve]"
    echo "DNS="
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

if ! verify_no_do_resolvers; then
    log "REVERTING — the change did not actually take effect"
    restore_backup "$STAMP"
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

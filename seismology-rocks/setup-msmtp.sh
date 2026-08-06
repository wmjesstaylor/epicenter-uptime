#!/bin/bash
# Sets up msmtp on seismology.rocks to relay through Proton, mirroring poseidon
# (epicenter-server deploy/scripts/setup-msmtp.sh). Idempotent — never
# overwrites an existing /etc/msmtprc.
#
#   sudo ./setup-msmtp.sh
#
# WHY NOT JUST USE POSTFIX. The box already runs postfix, but stock: myhostname
# is still the droplet image default (packer-…) and relayhost is empty, so it
# delivers direct-to-MX. Proton rejects that outright:
#
#   504 5.5.2 <jess@packer-60927f1a-…>: Sender address rejected:
#              need fully-qualified address
#
# Fixing myhostname would clear the 504 and then hit the next wall — no SPF for
# this droplet IP, no DKIM, no matching rDNS — so mail would be refused or
# spam-foldered anyway. Authenticated submission through Proton sidesteps all of
# it: Proton is the sender, and deliverability is their problem, not ours.
#
# Postfix stays installed for LOCAL mail (cron output to root), which works fine
# and is what the existing "delivered to mailbox" log lines are.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

echo "=== installing msmtp ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y msmtp msmtp-mta ca-certificates

if [ -e /etc/msmtprc ]; then
    echo "=== /etc/msmtprc already exists — leaving it untouched ==="
else
    echo "=== writing /etc/msmtprc template ==="
    cat > /etc/msmtprc <<'EOF'
# /etc/msmtprc — relays through ProtonMail SMTP submission for odysseymaps.io.
# Same account name ("proton") as poseidon, so scripts written for one host work
# on the other unchanged.

defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        proton
host           smtp.protonmail.ch
port           587
from           info@odysseymaps.io
user           SMTP_USERNAME_HERE
password       SMTP_TOKEN_HERE

account default : proton
EOF
    chown root:root /etc/msmtprc
    chmod 0600 /etc/msmtprc
    echo "Wrote /etc/msmtprc — REPLACE SMTP_USERNAME_HERE and SMTP_TOKEN_HERE"
    echo "with the same Proton SMTP credentials poseidon uses."
fi
ls -l /etc/msmtprc

touch /var/log/msmtp.log
chown root:root /var/log/msmtp.log
chmod 0600 /var/log/msmtp.log

echo
echo "=== next ==="
echo "1. Fill in the two credential fields:   sudo nano /etc/msmtprc"
echo "2. Test:"
echo "     printf 'Subject: msmtp test\\n\\nworks\\n' | msmtp -a proton seismology.rocks@protonmail.com"
echo "     sudo tail -5 /var/log/msmtp.log"
echo "3. Point the probe at email:            sudo nano /etc/epicenter-feed-probe.env"
echo "     set ALERT_EMAIL=seismology.rocks@protonmail.com"
echo
echo "The probe prefers msmtp over sendmail automatically once it is present."

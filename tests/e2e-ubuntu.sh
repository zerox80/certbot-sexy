#!/usr/bin/env bash
# Ende-zu-Ende auf einem Ubuntu mit laufendem systemd (GitHub-Runner): die Erneuerungs-Timer
# werden wirklich aktiviert. Cloudflare und Let's Encrypt sind wie im Container-Test Attrappen.
set -euo pipefail
cd "$(dirname "$0")/.."
GUT=test_token_mit_schreibrecht_0123456789

python3 tests/cloudflare-attrappe.py 8765 &
sudo install -m 755 tests/certbot-attrappe.sh /usr/local/sbin/certbot
sleep 1
run() {
  sudo env ZC_TEST_API=http://127.0.0.1:8765/client/v4 CLOUDFLARE_API_TOKEN="$GUT" \
    bash ./zertifikat-cloudflare.sh "$@" </dev/null
}

echo "---- Timer aus dem Paket (certbot.timer)"
run -d example.org --yes | tee /tmp/e2e1
systemctl is-active --quiet certbot.timer
grep -q "certbot.timer" /tmp/e2e1
echo "ok: certbot.timer aktiv"

echo "---- Ohne Timer aus dem Paket wird ein eigener angelegt"
sudo systemctl disable --now certbot.timer
sudo systemctl mask certbot.timer
run -d example.org -n zweites --yes | tee /tmp/e2e2
systemctl is-active --quiet certbot-erneuern.timer
systemctl cat certbot-erneuern.service | grep -q 'ExecStart=.*certbot -q renew'
sudo systemctl unmask certbot.timer
echo "ok: certbot-erneuern.timer aktiv"

echo "---- Status"
run --status | tee /tmp/e2e3
grep -q "certbot-erneuern.timer aktiv" /tmp/e2e3

echo ""
echo "==== Ende-zu-Ende bestanden"

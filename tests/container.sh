#!/usr/bin/env bash
# Läuft als root in einem frischen Container: echte Paketinstallation von certbot und dem
# Cloudflare-Plugin; Cloudflare-API und Let's Encrypt sind durch Attrappen ersetzt.
#   docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash /src/tests/container.sh
set -euo pipefail
script=/src/zertifikat-cloudflare.sh
GUT=test_token_mit_schreibrecht_0123456789
GUT2=test_token_zweiter_mit_schreibrecht_42
NUR_LESEN=test_token_nur_lesen_0123456789abcdef
export ZC_TEST_API=http://127.0.0.1:8765/client/v4
unset CLOUDFLARE_API_TOKEN

step() { printf '\n---- %s\n' "$*"; }
must_fail() { # erwartete Meldung, Befehl …
  local expect="$1"; shift
  if "$@" </dev/null >/tmp/out 2>&1; then cat /tmp/out; echo "FEHLER: hätte scheitern müssen: $*"; exit 1; fi
  grep -qF -- "$expect" /tmp/out || { cat /tmp/out; echo "FEHLER: Meldung fehlt: $expect"; exit 1; }
  echo "ok: scheitert mit „$expect“"
}
no_token_in() {
  if grep -qF -e "$GUT" -e "$GUT2" -e "$NUR_LESEN" "$1"; then echo "FEHLER: Token steht in der Ausgabe ($1)"; exit 1; fi
}
fingerprint() { find /etc/letsencrypt /root/.secrets -type f 2>/dev/null | sort | md5sum; }

step "Grundpakete für die Attrappen"
if command -v apt-get >/dev/null; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 openssl bsdutils >/dev/null
elif command -v dnf >/dev/null; then
  dnf install -y -q python3 openssl util-linux findutils >/dev/null
  dnf install -y -q util-linux-script >/dev/null 2>&1 || true
elif command -v zypper >/dev/null; then
  # Nur für die Testwerkzeuge (find); das Skript selbst braucht weder find noch awk.
  zypper -n -q install python3 openssl util-linux findutils >/dev/null
fi
python3 /src/tests/cloudflare-attrappe.py 8765 &
install -m 755 /src/tests/certbot-attrappe.sh /usr/local/sbin/certbot
sleep 1

step "Hilfe und falsche Aufrufe"
bash "$script" --help | grep -q -- "--domain"
bash "$script" --version | grep -q "zertifikat-cloudflare.sh"
must_fail "Unbekannte Option" bash "$script" --gibtsnicht
must_fail "--domain fehlt" bash "$script"
must_fail "keine gültige Domain" bash "$script" -d 'kaputt_!' --yes
must_fail "Kein Cloudflare-Token" bash "$script" -d example.org --yes
must_fail "zu kurz" env CLOUDFLARE_API_TOKEN=kurz bash "$script" -d example.org --yes

step "Erstes Holen – installiert certbot und das Cloudflare-Plugin"
CLOUDFLARE_API_TOKEN=$GUT bash "$script" -d example.org -d '*.example.org' -d WWW.example.org --yes </dev/null 2>&1 | tee /tmp/lauf1
no_token_in /tmp/lauf1
cred=/root/.secrets/certbot/example.org.ini
[[ "$(stat -c '%a %U' "$cred")" == "600 root" ]] || { echo "FEHLER: Rechte der Token-Datei"; exit 1; }
[[ "$(stat -c '%a' /root/.secrets/certbot)" == 700 ]] || { echo "FEHLER: Rechte des Ordners"; exit 1; }
grep -qx "dns_cloudflare_api_token = $GUT" "$cred"
grep -qx 'authenticator = dns-cloudflare' /etc/letsencrypt/renewal/example.org.conf
grep -q 'POST /client/v4/zones/zone-example-org/dns_records' /tmp/cloudflare-aufrufe
grep -q 'DELETE /client/v4/zones/zone-example-org/dns_records/eintrag-1' /tmp/cloudflare-aufrufe
grep -q -- '-d www.example.org' /tmp/certbot-aufrufe || { echo "FEHLER: Domain nicht klein geschrieben"; exit 1; }
grep -q 'Fertig' /tmp/lauf1
echo "ok: Zertifikat, Token-Datei (600, root) und Erneuerung eingerichtet"

step "Das echte certbot nimmt alle Optionen an, die das Skript benutzt"
# Manche Optionen stehen je nach Version nicht mehr in der Hilfe (z. B. certbot 5:
# --register-unsafely-without-email), werden aber weiter angenommen. Deshalb das echte certbot
# genau so aufrufen wie das Skript – gegen einen nicht erreichbaren ACME-Server, damit nichts
# nach außen geht. Unbekannte Optionen meldet certbot vorher mit "unrecognized arguments".
for real in /usr/bin/certbot /opt/certbot/bin/certbot; do [[ -x "$real" ]] && break; done
parses() { # certbot-Argumente … → scheitert, wenn certbot sie nicht kennt
  "$real" "$@" --server http://127.0.0.1:9/directory >/tmp/parse 2>&1 || true
  if grep -qE "unrecognized arguments|error: argument|ambiguous option" /tmp/parse; then
    cat /tmp/parse; echo "FEHLER: certbot $real lehnt Optionen ab: $*"; exit 1
  fi
}
printf 'dns_cloudflare_api_token = %s\n' "$GUT" >/tmp/cf.ini && chmod 600 /tmp/cf.ini
base=(certonly --non-interactive --agree-tos --authenticator dns-cloudflare
  --dns-cloudflare-credentials /tmp/cf.ini --dns-cloudflare-propagation-seconds 30
  --cert-name parse.example.org --key-type ecdsa --expand -d parse.example.org)
parses "${base[@]}" --register-unsafely-without-email --keep-until-expiring --dry-run --deploy-hook true
parses "${base[@]}" -m test@example.org --force-renewal --dry-run
parses renew --dry-run --no-random-sleep-on-renew --cert-name gibtsnicht
"$real" --help all 2>&1 | grep -q -- "--test-cert" || { echo "FEHLER: certbot kennt --test-cert nicht"; exit 1; }
certbot plugins --prepare 2>/dev/null | grep -q dns-cloudflare
echo "ok: $(certbot --version 2>&1)"

step "Kopfzeile zeigt die Skriptversion, nicht die des Systems"
grep -q "==> zertifikat-cloudflare.sh 1\." /tmp/lauf1 || { grep "==> zertifikat" /tmp/lauf1; echo "FEHLER: falsche Version"; exit 1; }
echo "ok"

step "Aufruf über eine Pipe wie bei curl … | bash"
bash -s -- --version <"$script" | grep -q "zertifikat-cloudflare.sh 1\."
CLOUDFLARE_API_TOKEN=$GUT bash -s -- -d example.org -n pipe --no-reload --yes <"$script" >/tmp/pipe 2>&1 || { cat /tmp/pipe; exit 1; }
[[ -f /etc/letsencrypt/renewal/pipe.conf ]]
grep -q "curl -fsSL https://raw.githubusercontent.com/zerox80/certbot-sexy/main/zertifikat-cloudflare.sh | sudo bash -s -- --status" /tmp/pipe
echo "ok"

step "Zweiter Lauf nimmt den gespeicherten Token"
bash "$script" -d example.org -d '*.example.org' -d www.example.org --yes </dev/null >/tmp/lauf2 2>&1 || { cat /tmp/lauf2; exit 1; }
grep -q "gespeichert in $cred" /tmp/lauf2
no_token_in /tmp/lauf2
echo "ok"

step "Fehlerfälle ändern den gespeicherten Token nicht"
must_fail "lehnt den Token ab" env CLOUDFLARE_API_TOKEN=falscher_token_aber_lang_genug_01 bash "$script" -d example.org --yes
must_fail "keine DNS-Einträge anlegen" env CLOUDFLARE_API_TOKEN=$NUR_LESEN bash "$script" -d example.org --yes
must_fail "findet der Token keine Zone" env CLOUDFLARE_API_TOKEN=$GUT bash "$script" -d app.example.net --yes
grep -qx "dns_cloudflare_api_token = $GUT" "$cred"
echo "ok: Token-Datei unverändert"

step "Token aus Datei, eigener Name, ohne Nachlauf-Befehl"
printf '%s\n' "$GUT" >/tmp/token && chmod 600 /tmp/token
bash "$script" -d example.org -n zweites --token-file /tmp/token --no-reload --yes </dev/null >/tmp/lauf3 2>&1 || { cat /tmp/lauf3; exit 1; }
[[ -f /root/.secrets/certbot/zweites.ini ]]
if grep -q '^renew_hook' /etc/letsencrypt/renewal/zweites.conf; then echo "FEHLER: Hook trotz --no-reload"; exit 1; fi
echo "ok"

step "Probelauf speichert nichts"
CLOUDFLARE_API_TOKEN=$GUT bash "$script" -d example.org -n probe --dry-run --yes </dev/null >/tmp/lauf4 2>&1 || { cat /tmp/lauf4; exit 1; }
grep -q "Probelauf erfolgreich" /tmp/lauf4
[[ ! -e /etc/letsencrypt/renewal/probe.conf && ! -e /root/.secrets/certbot/probe.ini ]]
[[ -z "$(find /tmp -maxdepth 1 -name 'tmp.*' -newer /tmp/token 2>/dev/null)" ]] || { echo "FEHLER: temporäre Token-Datei bleibt liegen"; exit 1; }
echo "ok"

step "Webserver wird erkannt und nach der Erneuerung neu geladen"
mkdir -p /etc/systemd/system
printf '[Service]\nExecStart=/bin/true\n' >/etc/systemd/system/nginx.service
CLOUDFLARE_API_TOKEN=$GUT bash "$script" -d example.org -n mitnginx --yes </dev/null >/tmp/lauf5 2>&1 || { cat /tmp/lauf5; exit 1; }
grep -qx 'renew_hook = if systemctl is-active --quiet nginx; then systemctl reload nginx; fi' /etc/letsencrypt/renewal/mitnginx.conf
rm /etc/systemd/system/nginx.service
echo "ok"

step "Token ersetzen"
CLOUDFLARE_API_TOKEN=$GUT2 bash "$script" --update-token -n example.org </dev/null >/tmp/lauf6 2>&1 || { cat /tmp/lauf6; exit 1; }
grep -qx "dns_cloudflare_api_token = $GUT2" "$cred"
no_token_in /tmp/lauf6
must_fail "Mehrere Zertifikate" env CLOUDFLARE_API_TOKEN=$GUT2 bash "$script" --update-token
echo "ok"

step "Status"
bash "$script" --status >/tmp/status 2>&1
grep -q "Certificate Name: example.org" /tmp/status
echo "ok"

step "Löschen"
must_fail "nur mit --yes" bash "$script" --remove zweites
mkdir -p /etc/nginx/sites-enabled
echo "ssl_certificate /etc/letsencrypt/live/zweites/fullchain.pem;" >/etc/nginx/sites-enabled/test
must_fail "noch eingebunden" bash "$script" --remove zweites --yes
rm /etc/nginx/sites-enabled/test
bash "$script" --remove zweites --yes </dev/null >/tmp/lauf7 2>&1 || { cat /tmp/lauf7; exit 1; }
[[ ! -e /etc/letsencrypt/renewal/zweites.conf && ! -e /root/.secrets/certbot/zweites.ini ]]
[[ -f "$cred" ]] || { echo "FEHLER: fremde Token-Datei gelöscht"; exit 1; }
echo "ok"

if command -v script >/dev/null; then
  step "Fragerunde im simulierten Terminal"
  # Antworten zeilenweise mit Pause – wie beim Tippen. Alles auf einmal käme schon vor der
  # verdeckten Token-Abfrage an, und das Terminal würde den Token (nur im Test) anzeigen.
  feed() { local line; for line in "$@"; do sleep 1; printf '%s\n' "$line"; done; }
  # Antworten: Domain, Token (verdeckt), E-Mail leer, Nachlauf-Befehl (Vorschlag), Bestätigung
  before="$(fingerprint)"
  feed interaktiv.example.org "$GUT" "" "" n | script -qec "bash $script" /dev/null >/tmp/fragen 2>&1 || true
  tr -d '\r' </tmp/fragen | grep -q "Abgebrochen – nichts geändert" || { cat /tmp/fragen; echo "FEHLER: kein Abbruch"; exit 1; }
  [[ "$(fingerprint)" == "$before" ]] || { echo "FEHLER: Abbruch hat etwas geändert"; exit 1; }
  no_token_in /tmp/fragen
  echo "ok: bei „n“ nichts geändert, Token nicht sichtbar"
  feed interaktiv.example.org "$GUT" "" "" j | script -qec "bash $script" /dev/null >/tmp/fragen 2>&1 || true
  [[ -f /etc/letsencrypt/renewal/interaktiv.example.org.conf ]] || { cat /tmp/fragen; echo "FEHLER: nicht ausgeführt"; exit 1; }
  no_token_in /tmp/fragen
  echo "ok: mit „j“ ausgeführt"
  # Falscher Token wird erkannt, danach klappt der richtige
  { feed zweiter.example.org falscher_token_aber_lang_genug_01 "" "" j; sleep 8; printf '%s\n' "$GUT"; } \
    | script -qec "bash $script" /dev/null >/tmp/fragen 2>&1 || true
  tr -d '\r' </tmp/fragen | grep -q "lehnt den Token ab" || { cat /tmp/fragen; echo "FEHLER: falscher Token nicht gemeldet"; exit 1; }
  [[ -f /etc/letsencrypt/renewal/zweiter.example.org.conf ]] || { cat /tmp/fragen; echo "FEHLER: zweiter Versuch nicht übernommen"; exit 1; }
  echo "ok: falscher Token erkannt, zweiter Versuch übernommen"
  # Wie "curl … | sudo bash": stdin ist das Skript, die Antworten kommen über /dev/tty
  feed curl.example.org "$GUT" "" "" j | script -qec "bash -s <$script" /dev/null >/tmp/fragen 2>&1 || true
  [[ -f /etc/letsencrypt/renewal/curl.example.org.conf ]] || { cat /tmp/fragen; echo "FEHLER: Fragen über /dev/tty klappen nicht"; exit 1; }
  no_token_in /tmp/fragen
  echo "ok: Fragen funktionieren auch bei curl … | bash"
fi

echo ""
echo "==== Alle Prüfungen bestanden ($(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release))"

#!/usr/bin/env bash
# zertifikat-cloudflare.sh – TLS-Zertifikat von Let's Encrypt über die DNS-Challenge (DNS-01)
# bei Cloudflare holen und automatisch erneuern lassen.
#
#   curl -fsSL https://raw.githubusercontent.com/zerox80/certbot-sexy/main/zertifikat-cloudflare.sh | sudo bash
#   … | sudo bash -s -- -d example.org --yes     – ohne Fragen (Optionen siehe --help)
#   … | sudo bash -s -- --status                 – Zertifikate und Erneuerung anzeigen
#
# Für Debian, Ubuntu, Fedora, Rocky/Alma Linux und openSUSE. Der Server braucht keinen offenen
# Port 80 und muss von außen nicht erreichbar sein – geprüft wird nur ein TXT-Eintrag im DNS.
#
# Alles steckt in Funktionen; ausgeführt wird erst in der letzten Zeile. So läuft bei
# "curl … | bash" nie ein halb geladenes Skript, und Befehle können kein Skript aus stdin lesen.
set -euo pipefail
umask 077
tmp_cred=""
trap 'if [[ -n "$tmp_cred" ]]; then rm -f "$tmp_cred"; fi' EXIT

SCRIPT_VERSION="1.0.0"
RAW_URL="https://raw.githubusercontent.com/zerox80/certbot-sexy/main/zertifikat-cloudflare.sh"
SECRETS_DIR="/root/.secrets/certbot"
LE_DIR="/etc/letsencrypt"
CF_API="https://api.cloudflare.com/client/v4"
# Nur für die Tests: Cloudflare-API durch eine lokale Attrappe ersetzen (ausschließlich 127.0.0.1).
if [[ -n "${ZC_TEST_API:-}" ]]; then
  [[ "$ZC_TEST_API" == http://127.0.0.1:* ]] || { echo "ZC_TEST_API darf nur auf 127.0.0.1 zeigen." >&2; exit 1; }
  CF_API="$ZC_TEST_API"
fi

# ---------------------------------------------------------------- Ausgabe
if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B="" G="" Y="" R="" N=""; fi
say()  { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '    %sok%s  %s\n' "$G" "$N" "$*"; }
warn() { printf '    %s!!%s  %s\n' "$Y" "$N" "$*" >&2; }
fail() { printf '\n%sFEHLER:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Aufruf: curl -fsSL https://raw.githubusercontent.com/zerox80/certbot-sexy/main/zertifikat-cloudflare.sh | sudo bash
        … | sudo bash -s -- -d DOMAIN [-d DOMAIN …] [Optionen] [--yes]
        sudo bash zertifikat-cloudflare.sh [Optionen]      (heruntergeladene Datei)

Zertifikat holen:
  -d, --domain NAME       Domain für das Zertifikat, mehrfach möglich, auch *.example.org.
                          Ohne Terminal Pflicht.
  -n, --name NAME         Name des Zertifikats (Ordner unter /etc/letsencrypt/live/).
                          Standard: erste Domain ohne "*.".
  -m, --email ADRESSE     Kontaktadresse für das Let's-Encrypt-Konto (freiwillig).
      --token-file DATEI  Cloudflare-API-Token aus dieser Datei lesen. Alternativ die
                          Umgebungsvariable CLOUDFLARE_API_TOKEN. Ohne beides: Abfrage im
                          Terminal oder der schon gespeicherte Token.
      --reload BEFEHL     Nach jeder Erneuerung ausführen. Standard: Webserver neu laden,
                          wenn Nginx, Apache oder HAProxy installiert ist.
      --no-reload         Nach einer Erneuerung nichts ausführen.
      --key-type TYP      ecdsa (Standard) oder rsa.
      --propagation SEK   Wartezeit, bis Cloudflare den TXT-Eintrag verteilt hat (Standard 30).
      --staging           Test-Zertifikat aus der Staging-Umgebung (nicht vertrauenswürdig,
                          ohne Ratenlimits). Name bekommt die Endung "-test".
      --dry-run           Alles prüfen und die Challenge durchspielen, nichts speichern.
      --force             Sofort neu ausstellen, auch wenn das Zertifikat noch lange gilt.
      --no-install        Keine Pakete installieren.
  -y, --yes               Ohne Rückfrage ausführen.

Verwalten:
      --status            Zertifikate, Ablaufdaten und automatische Erneuerung anzeigen.
      --update-token      Gespeicherten Cloudflare-Token ersetzen (bei mehreren Zertifikaten
                          mit -n NAME) und die Erneuerung testen.
      --remove NAME       Zertifikat und gespeicherten Token löschen.
  -h, --help              Diese Hilfe.
  -V, --version           Version anzeigen.

Der Token braucht bei Cloudflare nur das Recht „Zone → DNS → Bearbeiten“ für die
betroffene Zone (Vorlage „Edit zone DNS“). Er liegt danach nur für root lesbar unter
/root/.secrets/certbot/NAME.ini.
EOF
}

# ---------------------------------------------------------------- Optionen
domains=()
cert_name="" name_given=0 email="" token_file="" reload_cmd="" reload_given=0
key_type="ecdsa" propagation=30 staging=0 dry_run=0 force=0 do_install=1 assume_yes=0
action="holen" target=""

need() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 braucht einen Wert."; }
parse_args() {
  while (( $# )); do
    case "$1" in
      -d|--domain) need "$@"; domains+=("$2"); shift 2 ;;
      -n|--name) need "$@"; cert_name="$2"; name_given=1; shift 2 ;;
      -m|--email) need "$@"; email="$2"; shift 2 ;;
      --token-file) need "$@"; token_file="$2"; shift 2 ;;
      --reload) need "$@"; reload_cmd="$2"; reload_given=1; shift 2 ;;
      --no-reload) reload_cmd=""; reload_given=1; shift ;;
      --key-type) need "$@"; key_type="$2"; shift 2 ;;
      --propagation) need "$@"; propagation="$2"; shift 2 ;;
      --staging) staging=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --force) force=1; shift ;;
      --no-install) do_install=0; shift ;;
      -y|--yes) assume_yes=1; shift ;;
      --status) action="status"; shift ;;
      --update-token) action="token"; shift ;;
      --remove) need "$@"; action="entfernen"; target="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -V|--version) echo "zertifikat-cloudflare.sh $SCRIPT_VERSION"; exit 0 ;;
      *) usage >&2; fail "Unbekannte Option: $1" ;;
    esac
  done
}

# So ruft man das Skript erneut auf – als Datei oder über curl.
self_cmd() {
  if [[ -f "$0" && "$0" == *.sh ]]; then printf 'sudo bash %s %s' "$0" "$*"
  else printf 'curl -fsSL %s | sudo bash -s -- %s' "$RAW_URL" "$*"; fi
}

# Eingaben kommen vom Terminal. Bei "curl … | sudo bash" ist stdin das Skript selbst,
# deshalb dann direkt von /dev/tty lesen. Ohne Terminal (Automatisierung, Tests) gibt es
# keine Rückfragen, es gelten nur die Optionen.
TTY="" interactive=0
detect_terminal() {
  if [[ -t 1 ]]; then
    if [[ -t 0 ]]; then TTY=/dev/stdin
    elif { : </dev/tty; } 2>/dev/null; then TTY=/dev/tty
    fi
  fi
  if [[ -n "$TTY" ]]; then interactive=1; fi
}
os_ids=""
detect_os() { # nur ID und ID_LIKE – /etc/os-release in einer Subshell lesen (setzt sonst VERSION u. a.)
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    os_ids="$(. /etc/os-release && echo " ${ID:-} ${ID_LIKE:-} ")"
  fi
}

# ---------------------------------------------------------------- Hilfsfunktionen
ask() { # Frage, Vorschlag → Antwort (Vorschlag bei leerer Eingabe)
  local answer prompt="$1"
  [[ -n "${2:-}" ]] && prompt+=" [$2]"
  read -r -p "    $prompt: " answer <"$TTY" || true
  printf '%s' "${answer:-${2:-}}"
}
ask_yes() { # Frage, Vorschlag j/n
  local a; a="$(ask "$1 (j/n)" "$2" | tr '[:upper:]' '[:lower:]')"
  [[ "$a" =~ ^(j|ja|y|yes)$ ]]
}
ask_token() {
  local t
  echo "    Cloudflare-API-Token eingeben (die Eingabe bleibt unsichtbar)."
  echo "    Anlegen: https://dash.cloudflare.com/profile/api-tokens → „Token erstellen“"
  echo "             → Vorlage „Edit zone DNS“ → Zonenressourcen: die Zone der Domain"
  while true; do
    read -r -s -p "    Token: " t <"$TTY" || true
    echo ""
    t="${t//[[:space:]]/}"
    [[ ${#t} -ge 20 ]] && break
    warn "Das sieht nicht nach einem API-Token aus (zu kurz)."
  done
  token="$t"
}
# Wert aus einer certbot-Renewal- oder Token-Datei: conf_value DATEI SCHLÜSSEL
# Reines bash – minimale Systeme (z. B. openSUSE Tumbleweed) haben kein awk.
conf_value() {
  local line val
  [[ -r "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*([^=[:space:]]+)[[:space:]]*=[[:space:]]*(.*)$ && "${BASH_REMATCH[1]}" == "$2" ]]; then
      val="${BASH_REMATCH[2]}"
      printf '%s' "${val%"${val##*[![:space:]]}"}"
      return 0
    fi
  done <"$1"
}
token_from_file() {
  [[ -r "$1" ]] || fail "Token-Datei $1 ist nicht lesbar."
  local t line
  t="$(conf_value "$1" dns_cloudflare_api_token)"
  if [[ -z "$t" ]]; then # nur der Token: erste Zeile, die kein Kommentar ist
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ ! "$line" =~ ^[[:space:]]*(#|$) ]]; then t="$line"; break; fi
    done <"$1"
  fi
  printf '%s' "${t//[[:space:]]/}"
}
unit_exists() {
  local d
  for d in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
    [[ -e "$d/$1.service" ]] && return 0
  done
  return 1
}
# Nach einer Erneuerung den Webserver neu laden – aber nur, wenn er läuft (sonst kein Fehler).
detect_reload() {
  local s
  for s in nginx apache2 httpd haproxy; do
    if unit_exists "$s" || command -v "$s" >/dev/null 2>&1; then
      printf 'if systemctl is-active --quiet %s; then systemctl reload %s; fi' "$s" "$s"
      return
    fi
  done
}
check_domains() {
  local d re='^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$'
  local bad=0 seen=" " out=()
  for d in "${domains[@]}"; do
    d="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "$d" =~ $re ]]; then warn "„$d“ ist keine gültige Domain."; bad=1; continue; fi
    [[ "$seen" == *" $d "* ]] && continue
    seen+="$d "
    out+=("$d")
  done
  domains=("${out[@]}")
  (( ! bad && ${#domains[@]} > 0 ))
}
cert_domains() { # Domains eines vorhandenen Zertifikats laut certbot
  local line list=()
  while IFS= read -r line; do
    if [[ "$line" =~ Domains:[[:space:]]*(.*)$ ]]; then
      read -r -a list <<<"${BASH_REMATCH[1]}"
      if (( ${#list[@]} )); then printf '%s\n' "${list[@]}"; fi
      return 0
    fi
  done < <(certbot certificates --cert-name "$1" 2>/dev/null)
}
next_run() {
  local n
  n="$(systemctl show "$1" -p NextElapseUSecRealtime --value 2>/dev/null || true)"
  [[ -n "$n" && "$n" != "n/a" ]] && printf '%s' "$n" || printf 'innerhalb von 12 Stunden'
}
find_python() {
  PY=""
  local p
  for p in python3 /opt/certbot/bin/python3; do
    if command -v "$p" >/dev/null 2>&1; then PY="$(command -v "$p")"; return; fi
  done
}

# ---------------------------------------------------------------- certbot installieren
have_plugin() { command -v certbot >/dev/null 2>&1 && certbot plugins --prepare 2>/dev/null | grep -q 'dns-cloudflare'; }

install_venv() {
  local py="" v
  for v in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
    if command -v "$v" >/dev/null 2>&1 \
      && "$v" -c 'import sys, ensurepip, venv; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
      py="$v"; break
    fi
  done
  if [[ -z "$py" ]]; then
    if command -v apt-get >/dev/null; then apt-get install -y -qq python3-venv >/dev/null || true; py=python3
    elif command -v zypper >/dev/null; then zypper -n -q install python311 >/dev/null || true; py=python3.11
    elif command -v dnf >/dev/null; then dnf install -y -q python3 >/dev/null || true; py=python3
    fi
  fi
  command -v "$py" >/dev/null 2>&1 || fail "Kein Python ab 3.9 gefunden – certbot lässt sich nicht installieren."
  "$py" -m venv /opt/certbot
  /opt/certbot/bin/pip install -q --disable-pip-version-check --upgrade pip
  /opt/certbot/bin/pip install -q --disable-pip-version-check certbot certbot-dns-cloudflare
  # /usr/bin liegt auch unter sudo im Suchpfad (RHEL: secure_path ohne /usr/local/bin)
  if [[ ! -e /usr/bin/certbot ]]; then ln -s /opt/certbot/bin/certbot /usr/bin/certbot
  else ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot; fi
  hash -r
}

install_certbot() {
  say "certbot mit Cloudflare-Plugin"
  if have_plugin; then ok "vorhanden: $(certbot --version 2>&1 | head -n 1)"; return; fi
  (( do_install )) || fail "certbot mit dem Plugin dns-cloudflare fehlt (--no-install ist gesetzt)."
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq certbot python3-certbot-dns-cloudflare >/dev/null || true
  elif command -v dnf >/dev/null; then
    # Rocky, Alma & Co.: certbot liegt in EPEL
    if [[ "$os_ids" == *" rhel "* ]] && ! rpm -q epel-release >/dev/null 2>&1; then
      dnf install -y -q epel-release >/dev/null 2>&1 || true
    fi
    dnf install -y -q certbot python3-certbot-dns-cloudflare >/dev/null 2>&1 || true
  elif command -v zypper >/dev/null; then
    zypper -n -q install certbot python3-certbot-dns-cloudflare >/dev/null 2>&1 || true
  fi
  hash -r
  if ! have_plugin; then
    warn "Keine passenden Pakete – certbot kommt in eine eigene Python-Umgebung unter /opt/certbot."
    install_venv
  fi
  have_plugin || fail "certbot mit dem Plugin dns-cloudflare ließ sich nicht installieren."
  ok "installiert: $(certbot --version 2>&1 | head -n 1)"
}

# ---------------------------------------------------------------- Cloudflare prüfen
# Prüft für jede Domain: Token gültig, Zone gefunden, TXT-Eintrag anlegen und wieder löschen.
# Der Token kommt über die Umgebung (nie über die Befehlszeile, also nicht in "ps" sichtbar).
read -r -d '' CF_CHECK_PY <<'PY' || true
import json, os, sys, urllib.error, urllib.parse, urllib.request

API, TOKEN = os.environ["CF_API"], os.environ["CF_TOKEN"]


def call(method, path, body=None):
    req = urllib.request.Request(
        API + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except ValueError:
            return {"success": False, "errors": [{"code": e.code, "message": str(e.reason)}]}
    except (urllib.error.URLError, OSError, ValueError) as e:
        print("FEHLER\tCloudflare ist nicht erreichbar (%s). Ausgehendes HTTPS zu "
              "api.cloudflare.com muss erlaubt sein." % e)
        sys.exit(5)


def why(res):
    errs = res.get("errors") or []
    return "; ".join("%s %s" % (x.get("code", ""), x.get("message", "")) for x in errs) or "ohne Begründung"


zones = {}
for domain in sys.argv[1:]:
    name = domain[2:] if domain.startswith("*.") else domain
    labels = name.split(".")
    zone = None
    for i in range(len(labels) - 1):
        candidate = ".".join(labels[i:])
        if candidate in zones:
            zone = candidate
            break
        res = call("GET", "/zones?" + urllib.parse.urlencode({"name": candidate}))
        if not res.get("success"):
            print("FEHLER\tCloudflare lehnt den Token ab (%s). Ist er vollständig kopiert? Ein "
                  "„Global API Key“ funktioniert hier nicht, nur ein API-Token." % why(res))
            sys.exit(2)
        if res.get("result"):
            zones[candidate] = res["result"][0]["id"]
            zone = candidate
            break
    if zone is None:
        print("FEHLER\tZu %s findet der Token keine Zone. Liegt die Domain bei Cloudflare, und "
              "gilt der Token für diese Zone?" % domain)
        sys.exit(3)
    print("OK\t%s liegt in der Cloudflare-Zone %s" % (domain, zone))

for zone, zone_id in zones.items():
    res = call("POST", "/zones/%s/dns_records" % zone_id,
               {"type": "TXT", "name": "_zertifikat-pruefung." + zone,
                "content": "zertifikat-cloudflare", "ttl": 60})
    if not res.get("success"):
        print("FEHLER\tDer Token darf in %s keine DNS-Einträge anlegen (%s). Nötig ist das "
              "Recht „Zone → DNS → Bearbeiten“." % (zone, why(res)))
        sys.exit(4)
    gone = call("DELETE", "/zones/%s/dns_records/%s" % (zone_id, res["result"]["id"]))
    if gone.get("success"):
        print("OK\tDer Token darf in %s DNS-Einträge anlegen und löschen" % zone)
    else:
        print("WARN\tPrüfeintrag _zertifikat-pruefung.%s ließ sich nicht löschen (%s) – bitte im "
              "Cloudflare-Dashboard entfernen." % (zone, why(gone)))
PY

check_token() {
  say "Cloudflare-Token prüfen"
  problem=""
  find_python
  if [[ -z "$PY" ]]; then
    warn "Kein python3 gefunden – den Token prüft erst certbot selbst."
    return 0
  fi
  local out rc=0 kind msg
  out="$(CF_TOKEN="$token" CF_API="$CF_API" "$PY" -I - "${domains[@]}" <<<"$CF_CHECK_PY" 2>&1)" || rc=$?
  while IFS=$'\t' read -r kind msg; do
    case "$kind" in
      OK) ok "$msg" ;;
      WARN) warn "$msg" ;;
      FEHLER) problem="$msg" ;;
    esac
  done <<<"$out"
  if (( rc )); then
    [[ -n "$problem" ]] || problem="Prüfung gescheitert (Code $rc): ${out:0:300}"
    return 1
  fi
}

write_credentials() { # Zieldatei – nur root darf lesen
  local file="$1" dir tmp
  dir="$(dirname "$file")"
  install -d -m 700 -o root -g root "$dir"
  tmp="$(mktemp "$dir/.token.XXXXXX")"
  printf '# Cloudflare-API-Token für certbot (zertifikat-cloudflare.sh) – nur für root lesbar\n' >"$tmp"
  printf 'dns_cloudflare_api_token = %s\n' "$token" >>"$tmp"
  chown root:root "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# ---------------------------------------------------------------- Erneuerung
renew_info=""
setup_renewal() {
  say "Automatische Erneuerung"
  local bin t
  bin="$(command -v certbot)"
  if [[ -d /run/systemd/system ]]; then
    # Timer aus dem Paket (Debian/Ubuntu: certbot.timer, Fedora/EPEL: certbot-renew.timer, Snap)
    for t in certbot.timer certbot-renew.timer snap.certbot.renew.timer; do
      if systemctl cat "$t" >/dev/null 2>&1; then
        systemctl enable --now "$t" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "$t"; then
          renew_info="$t (prüft zweimal täglich), nächster Lauf: $(next_run "$t")"
          ok "$renew_info"
          return
        fi
      fi
    done
    # Kein Timer aus dem Paket (z. B. certbot in /opt/certbot): eigenen anlegen
    cat >/etc/systemd/system/certbot-erneuern.service <<EOF
[Unit]
Description=Zertifikate mit certbot erneuern (zertifikat-cloudflare.sh)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$bin -q renew
EOF
    cat >/etc/systemd/system/certbot-erneuern.timer <<'EOF'
[Unit]
Description=Zertifikate zweimal täglich auf fällige Erneuerung prüfen

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 /etc/systemd/system/certbot-erneuern.service /etc/systemd/system/certbot-erneuern.timer
    systemctl daemon-reload
    systemctl enable --now certbot-erneuern.timer >/dev/null 2>&1
    renew_info="certbot-erneuern.timer (prüft zweimal täglich), nächster Lauf: $(next_run certbot-erneuern.timer)"
    ok "$renew_info"
    return
  fi
  # Ohne systemd (z. B. Container): cron
  if [[ -f /etc/cron.d/certbot ]]; then
    renew_info="cron (/etc/cron.d/certbot, zweimal täglich)"
  elif [[ -d /etc/cron.d ]]; then
    printf '# zertifikat-cloudflare.sh: zweimal täglich prüfen, certbot erneuert nur bei Bedarf\n%d */12 * * * root %s -q renew\n' \
      $(( RANDOM % 60 )) "$bin" >/etc/cron.d/zertifikat-cloudflare
    chmod 644 /etc/cron.d/zertifikat-cloudflare
    renew_info="cron (/etc/cron.d/zertifikat-cloudflare, zweimal täglich)"
  else
    renew_info="nicht eingerichtet"
    warn "Weder systemd noch cron gefunden – 'certbot renew' bitte selbst regelmäßig ausführen lassen."
    return
  fi
  ok "$renew_info"
}

renew_test() {
  say "Erneuerung testen (Probelauf gegen die Staging-Umgebung, ändert nichts)"
  if certbot renew --dry-run --no-random-sleep-on-renew --cert-name "$cert_name"; then
    ok "Die automatische Erneuerung funktioniert."
  else
    warn "Probelauf der Erneuerung gescheitert – Details: /var/log/letsencrypt/letsencrypt.log"
  fi
}

# ---------------------------------------------------------------- Aktionen
show_status() {
  command -v certbot >/dev/null 2>&1 || fail "certbot ist nicht installiert."
  say "Zertifikate"
  certbot certificates 2>/dev/null || true
  say "Automatische Erneuerung"
  local t found=0
  if [[ -d /run/systemd/system ]]; then
    for t in certbot.timer certbot-renew.timer snap.certbot.renew.timer certbot-erneuern.timer; do
      if systemctl is-active --quiet "$t" 2>/dev/null; then
        ok "$t aktiv, nächster Lauf: $(next_run "$t")"; found=1
      fi
    done
  fi
  for t in /etc/cron.d/certbot /etc/cron.d/zertifikat-cloudflare; do
    [[ -f "$t" ]] && { ok "cron: $t"; found=1; }
  done
  (( found )) || warn "Keine automatische Erneuerung gefunden – Skript erneut ausführen."
}

pick_cert_name() { # bei mehreren Zertifikaten mit Cloudflare-DNS nachfragen
  [[ -n "$cert_name" ]] && return
  local names=() f
  for f in "$LE_DIR"/renewal/*.conf; do
    [[ -f "$f" && "$(conf_value "$f" authenticator)" == dns-cloudflare ]] && names+=("$(basename "$f" .conf)")
  done
  (( ${#names[@]} )) || fail "Kein Zertifikat mit Cloudflare-DNS-Challenge gefunden."
  if (( ${#names[@]} == 1 )); then
    cert_name="${names[0]}"
  elif (( interactive )); then
    echo "    Zertifikate: ${names[*]}"
    cert_name="$(ask "Für welches Zertifikat" "${names[0]}")"
  else
    fail "Mehrere Zertifikate (${names[*]}) – bitte mit -n NAME wählen."
  fi
}

get_new_token() { # aus Datei, Umgebung oder Abfrage
  if [[ -n "$token_file" ]]; then token="$(token_from_file "$token_file")"
  elif [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then token="${CLOUDFLARE_API_TOKEN//[[:space:]]/}"
  elif (( interactive )); then ask_token
  else fail "Kein Cloudflare-Token: --token-file DATEI oder CLOUDFLARE_API_TOKEN setzen."
  fi
}

verify_token_loop() { # im Terminal bis zu drei Versuche
  local tries=1
  until check_token; do
    if (( interactive && tries < 3 )); then
      warn "$problem"
      tries=$(( tries + 1 ))
      ask_token
    else
      fail "$problem"
    fi
  done
}

update_token() {
  say "zertifikat-cloudflare.sh $SCRIPT_VERSION – Token ersetzen"
  command -v certbot >/dev/null 2>&1 || fail "certbot ist nicht installiert."
  pick_cert_name
  local conf="$LE_DIR/renewal/$cert_name.conf"
  [[ -f "$conf" ]] || fail "Ein Zertifikat „$cert_name“ gibt es nicht."
  cred="$(conf_value "$conf" dns_cloudflare_credentials)"
  [[ -n "$cred" ]] || fail "„$cert_name“ nutzt nicht die Cloudflare-DNS-Challenge."
  mapfile -t domains < <(cert_domains "$cert_name")
  (( ${#domains[@]} )) || fail "Die Domains von „$cert_name“ ließen sich nicht lesen."
  ok "Zertifikat $cert_name: ${domains[*]}"
  get_new_token
  verify_token_loop
  write_credentials "$cred"
  ok "Neuer Token gespeichert in $cred"
  renew_test
  echo ""
  echo "    Den alten Token bei Cloudflare löschen (https://dash.cloudflare.com/profile/api-tokens)."
}

remove_cert() {
  say "zertifikat-cloudflare.sh $SCRIPT_VERSION – Zertifikat löschen"
  command -v certbot >/dev/null 2>&1 || fail "certbot ist nicht installiert."
  local conf="$LE_DIR/renewal/$target.conf" users
  [[ -f "$conf" ]] || fail "Ein Zertifikat „$target“ gibt es nicht."
  cred="$(conf_value "$conf" dns_cloudflare_credentials)"
  users="$(grep -rlsF "$LE_DIR/live/$target/" /etc/nginx /etc/apache2 /etc/httpd /etc/haproxy 2>/dev/null || true)"
  if [[ -n "$users" ]] && (( ! force )); then
    fail "Das Zertifikat ist noch eingebunden in: $(echo "$users" | tr '\n' ' ')– erst dort entfernen (oder --force)."
  fi
  if (( ! assume_yes )); then
    (( interactive )) || fail "Löschen ohne Terminal nur mit --yes."
    ask_yes "Zertifikat „$target“ und den gespeicherten Token löschen?" "n" || { ok "Abgebrochen – nichts geändert."; exit 0; }
  fi
  certbot delete --cert-name "$target" --non-interactive
  ok "Zertifikat $target gelöscht"
  # Token nur löschen, wenn er von diesem Skript stammt und kein anderes Zertifikat ihn nutzt
  if [[ "$cred" == "$SECRETS_DIR/"* && -f "$cred" ]] && ! grep -qsF "$cred" "$LE_DIR"/renewal/*.conf; then
    rm -f "$cred"
    ok "Token gelöscht ($cred)"
    echo "    Den Token auch bei Cloudflare löschen, falls er nirgends mehr gebraucht wird."
  fi
}

obtain() {
  say "zertifikat-cloudflare.sh $SCRIPT_VERSION"
  [[ "$key_type" =~ ^(ecdsa|rsa)$ ]] || fail "--key-type: nur ecdsa oder rsa."
  if [[ ! "$propagation" =~ ^[0-9]+$ ]] || (( propagation > 600 )); then
    fail "--propagation: Sekunden von 0 bis 600."
  fi

  # 1. Domains
  if (( ${#domains[@]} == 0 )); then
    (( interactive )) || { usage >&2; fail "--domain fehlt (oder das Skript in einem Terminal starten, dann fragt es nach)."; }
    say "Ein paar Fragen – geändert wird erst nach deiner Bestätigung (Vorschlag mit Enter übernehmen)"
    local suggestion
    suggestion="$(hostname -f 2>/dev/null || true)"
    [[ "$suggestion" == *.* && ! "$suggestion" =~ \.(local|lan|home|internal|localdomain)$ ]] || suggestion=""
    while true; do
      read -r -a domains <<<"$(ask "Domain(s) für das Zertifikat, mehrere mit Leerzeichen (auch *.example.org)" "$suggestion")"
      (( ${#domains[@]} )) && check_domains && break
      warn "Bitte eine oder mehrere Domains angeben, z. B. example.org www.example.org"
    done
  else
    check_domains || fail "Ungültige Domain – erlaubt sind z. B. example.org, app.example.org, *.example.org."
    (( interactive )) && say "Ein paar Fragen – geändert wird erst nach deiner Bestätigung (Vorschlag mit Enter übernehmen)"
  fi
  if (( ! name_given )); then
    cert_name="${domains[0]#\*.}"
    (( staging )) && cert_name+="-test"
  fi
  [[ "$cert_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "--name: nur Buchstaben, Ziffern, Punkt, Minus und Unterstrich."
  [[ -z "$email" || "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || fail "--email: keine gültige Adresse."

  # 2. Vorhandenes Zertifikat
  local conf="$LE_DIR/renewal/$cert_name.conf" existing=0 old_auth="" old_hook="" c
  cred="$SECRETS_DIR/$cert_name.ini"
  if [[ -f "$conf" ]]; then
    existing=1
    old_auth="$(conf_value "$conf" authenticator)"
    old_hook="$(conf_value "$conf" renew_hook)"
    c="$(conf_value "$conf" dns_cloudflare_credentials)"
    [[ -n "$c" ]] && cred="$c"
    if [[ -n "$old_auth" && "$old_auth" != dns-cloudflare ]] && (( ! force )); then
      ok "„$cert_name“ nutzt bisher die Prüfung „$old_auth“ – wird auf Cloudflare-DNS umgestellt und dafür neu ausgestellt."
      force=1
    fi
  fi

  # 3. Token
  local token_src=""
  token=""
  if [[ -n "$token_file" || -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    get_new_token
    token_src="${token_file:-Umgebungsvariable CLOUDFLARE_API_TOKEN}"
  elif [[ -f "$cred" ]] && token="$(token_from_file "$cred")" && [[ -n "$token" ]]; then
    token_src="gespeichert in $cred"
    if (( interactive )) && ! ask_yes "Gespeicherten Cloudflare-Token verwenden?" "j"; then
      ask_token
      token_src="neu eingegeben"
    fi
  else
    get_new_token
    token_src="neu eingegeben"
  fi
  [[ "$token" =~ ^[[:graph:]]{20,}$ ]] || fail "Der Cloudflare-Token sieht ungültig aus (zu kurz oder mit Leerzeichen)."

  # 4. E-Mail (nur beim ersten Konto) und Befehl nach der Erneuerung
  if (( interactive )) && [[ -z "$email" ]] && ! compgen -G "$LE_DIR/accounts/*/directory/*" >/dev/null; then
    email="$(ask "E-Mail für das Let's-Encrypt-Konto (freiwillig, Enter = ohne)" "")"
    [[ -z "$email" || "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { warn "Keine gültige Adresse – ohne E-Mail weiter."; email=""; }
  fi
  if (( ! reload_given )); then
    reload_cmd="$(detect_reload)"
    if (( interactive )); then
      local a
      a="$(ask "Nach jeder Erneuerung ausführen ('-' = nichts)" "${reload_cmd:--}")"
      if [[ "$a" == "-" ]]; then reload_cmd=""; else reload_cmd="$a"; fi
    fi
  fi
  if (( existing && ! force )) && [[ -n "$reload_cmd" && "$reload_cmd" != "$old_hook" ]]; then
    warn "Der Befehl nach der Erneuerung weicht vom gespeicherten ab – er wird erst mit --force übernommen."
  fi

  # 5. Zusammenfassung
  say "Zusammenfassung"
  echo "    Domains:      ${domains[*]}"
  echo "    Name:         $cert_name  ($LE_DIR/live/$cert_name/)"
  if (( existing )); then
    if (( force )); then echo "    Vorhanden:    ja – wird sofort neu ausgestellt"
    else echo "    Vorhanden:    ja – erneuert nur, wenn es bald abläuft oder Domains dazukommen"; fi
  fi
  if (( staging )); then echo "    Aussteller:   Let's Encrypt Staging (Test-Zertifikat, nicht vertrauenswürdig)"
  else echo "    Aussteller:   Let's Encrypt"; fi
  echo "    Schlüssel:    $key_type"
  echo "    E-Mail:       ${email:-ohne}"
  echo "    Token:        $token_src"
  echo "    Danach:       ${reload_cmd:-nichts}"
  if (( dry_run )); then echo "    Probelauf:    ja – es wird nichts gespeichert"; fi
  if (( interactive && ! assume_yes )); then
    echo ""
    ask_yes "So ausführen?" "j" || { ok "Abgebrochen – nichts geändert."; exit 0; }
  fi

  # 6. Ausführen
  install_certbot
  verify_token_loop
  local run_cred="$cred"
  if (( dry_run )); then
    tmp_cred="$(mktemp)"
    run_cred="$tmp_cred"
    printf 'dns_cloudflare_api_token = %s\n' "$token" >"$run_cred"
  else
    write_credentials "$cred"
    ok "Token gespeichert (nur root): $cred"
  fi

  local args=(certonly --non-interactive --agree-tos
    --authenticator dns-cloudflare
    --dns-cloudflare-credentials "$run_cred"
    --dns-cloudflare-propagation-seconds "$propagation"
    --cert-name "$cert_name" --key-type "$key_type" --expand)
  local d
  for d in "${domains[@]}"; do args+=(-d "$d"); done
  if [[ -n "$email" ]]; then args+=(-m "$email"); else args+=(--register-unsafely-without-email); fi
  if (( force )); then args+=(--force-renewal); else args+=(--keep-until-expiring); fi
  if (( dry_run )); then args+=(--dry-run); elif (( staging )); then args+=(--test-cert); fi
  if [[ -n "$reload_cmd" ]]; then args+=(--deploy-hook "$reload_cmd"); fi

  say "Zertifikat anfordern (DNS-Challenge, dauert etwa $(( propagation + 20 )) Sekunden)"
  if ! certbot "${args[@]}"; then
    fail "certbot ist gescheitert. Details: /var/log/letsencrypt/letsencrypt.log
       Häufige Ursachen: Ratenlimit (zum Ausprobieren --staging), DNS-Eintrag noch nicht
       verteilt (--propagation 60) oder eine CAA-Regel der Domain erlaubt Let's Encrypt nicht."
  fi
  if (( dry_run )); then
    say "Probelauf erfolgreich – nichts gespeichert. Ohne --dry-run ausführen, um das Zertifikat zu holen."
    return
  fi

  setup_renewal
  (( staging )) || renew_test

  # 7. Ergebnis
  local live="$LE_DIR/live/$cert_name" end=""
  if command -v openssl >/dev/null 2>&1 && [[ -r "$live/cert.pem" ]]; then
    end="$(openssl x509 -enddate -noout -in "$live/cert.pem")"
    end="${end#*=}"
    end="$(date -d "$end" '+%d.%m.%Y %H:%M' 2>/dev/null || printf '%s' "$end")"
  fi
  say "Fertig"
  echo "    Zertifikat:   $live/fullchain.pem"
  echo "    Schlüssel:    $live/privkey.pem"
  if [[ -n "$end" ]]; then echo "    Gültig bis:   $end (wird etwa 30 Tage vorher erneuert)"; fi
  echo "    Domains:      ${domains[*]}"
  echo "    Token:        $cred (nur root)"
  echo "    Erneuerung:   ${renew_info:-siehe oben}"
  echo "    Danach:       ${reload_cmd:-nichts}"
  echo ""
  echo "    Für Nginx:"
  echo "      ssl_certificate     $live/fullchain.pem;"
  echo "      ssl_certificate_key $live/privkey.pem;"
  echo ""
  echo "    Status später: $(self_cmd --status)"
}

main() {
  parse_args "$@"
  if (( EUID != 0 )); then
    fail "Bitte als root ausführen: $(self_cmd "$@")"
  fi
  detect_terminal
  detect_os
  case "$action" in
    holen) obtain ;;
    status) show_status ;;
    token) update_token ;;
    entfernen) remove_cert ;;
  esac
}

main "$@"

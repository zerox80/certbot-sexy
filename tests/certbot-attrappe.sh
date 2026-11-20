#!/usr/bin/env bash
# Attrappe für die Tests (liegt als /usr/local/sbin/certbot vor dem echten certbot im Suchpfad):
# certonly, renew, certificates und delete ohne Let's Encrypt – alles andere geht an das echte
# certbot, damit Plugin-Erkennung und "--help all" echt geprüft werden.
set -euo pipefail
echo "certbot $*" >>/tmp/certbot-aufrufe
le=/etc/letsencrypt
real=""
# Sich selbst überspringen: Auf Fedora ist /usr/local/sbin nur ein Link auf /usr/local/bin.
for p in /usr/bin/certbot /usr/local/bin/certbot /opt/certbot/bin/certbot /snap/bin/certbot; do
  if [[ -x "$p" && ! "$p" -ef "${BASH_SOURCE[0]}" ]]; then real="$p"; break; fi
done

case "${1:-}" in
  certonly)
    shift
    name="" cred="" hook="" auth="" dry=0 force=0 domains=()
    while (( $# )); do
      case "$1" in
        --cert-name) name="$2"; shift 2 ;;
        -d) domains+=("$2"); shift 2 ;;
        --dns-cloudflare-credentials) cred="$2"; shift 2 ;;
        --deploy-hook) hook="$2"; shift 2 ;;
        --authenticator) auth="$2"; shift 2 ;;
        --dns-cloudflare-propagation-seconds|--key-type|-m) shift 2 ;;
        --dry-run) dry=1; shift ;;
        --force-renewal) force=1; shift ;;
        *) shift ;;
      esac
    done
    [[ "$auth" == dns-cloudflare ]] || { echo "Attrappe: falscher Authenticator '$auth'" >&2; exit 1; }
    [[ "$(stat -c %a "$cred")" == 600 ]] || { echo "Attrappe: Token-Datei ist nicht 600" >&2; exit 1; }
    grep -q '^dns_cloudflare_api_token = ' "$cred" || { echo "Attrappe: Token fehlt in $cred" >&2; exit 1; }
    if (( dry )); then echo "The dry run was successful."; exit 0; fi
    if [[ -f "$le/renewal/$name.conf" ]] && (( ! force )); then
      echo "Certificate not yet due for renewal; no action taken."
      exit 0
    fi
    mkdir -p "$le/live/$name" "$le/renewal"
    san="$(printf 'DNS:%s,' "${domains[@]}")"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 90 \
      -subj "/CN=${domains[0]}" -addext "subjectAltName=${san%,}" \
      -keyout "$le/live/$name/privkey.pem" -out "$le/live/$name/cert.pem" 2>/dev/null
    cp "$le/live/$name/cert.pem" "$le/live/$name/fullchain.pem"
    cp "$le/live/$name/cert.pem" "$le/live/$name/chain.pem"
    {
      echo "version = 0.0.0-attrappe"
      echo "[renewalparams]"
      echo "authenticator = dns-cloudflare"
      echo "dns_cloudflare_credentials = $cred"
      if [[ -n "$hook" ]]; then echo "renew_hook = $hook"; fi
    } >"$le/renewal/$name.conf"
    echo "Successfully received certificate."
    ;;
  renew)
    echo "Congratulations, all simulated renewals succeeded"
    ;;
  certificates)
    shift
    only=""
    if [[ "${1:-}" == --cert-name ]]; then only="$2"; fi
    for f in "$le"/renewal/*.conf; do
      [[ -f "$f" ]] || continue
      n="$(basename "$f" .conf)"
      [[ -z "$only" || "$only" == "$n" ]] || continue
      d="$(openssl x509 -noout -text -in "$le/live/$n/cert.pem" | grep -o 'DNS:[^,]*' | sed 's/DNS://' | tr '\n' ' ')"
      echo "  Certificate Name: $n"
      echo "    Domains: ${d% }"
    done
    ;;
  delete)
    shift
    name=""
    while (( $# )); do
      case "$1" in --cert-name) name="$2"; shift 2 ;; *) shift ;; esac
    done
    rm -rf "${le:?}/live/$name" "$le/renewal/$name.conf"
    ;;
  *)
    [[ -n "$real" ]] || exit 1
    exec "$real" "$@"
    ;;
esac

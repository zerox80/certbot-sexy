# certbot-sexy

TLS-Zertifikat von Let's Encrypt über die DNS-Challenge bei Cloudflare – mit einem Befehl,
inklusive automatischer Erneuerung. Der Server braucht dafür **keinen offenen Port 80** und muss
von außen nicht erreichbar sein: Let's Encrypt prüft nur einen TXT-Eintrag im DNS. Das passt für
interne Server, Server hinter einer Firewall und Wildcard-Zertifikate (`*.example.org`).

## Schnellstart

```bash
curl -fsSL https://raw.githubusercontent.com/zerox80/certbot-sexy/main/zertifikat-cloudflare.sh | sudo bash
```

Das Skript fragt nach den Domains und dem Cloudflare-API-Token (die Eingabe bleibt unsichtbar),
zeigt eine Zusammenfassung und legt erst nach deiner Bestätigung los:

```text
==> Zusammenfassung
    Domains:      app.example.org
    Name:         app.example.org  (/etc/letsencrypt/live/app.example.org/)
    Aussteller:   Let's Encrypt
    Schlüssel:    ecdsa
    E-Mail:       ohne
    Token:        neu eingegeben
    Danach:       if systemctl is-active --quiet nginx; then systemctl reload nginx; fi

    So ausführen? (j/n) [j]:
```

Danach:

1. installiert es certbot und das Cloudflare-Plugin aus den Paketquellen der Distribution
   (falls nötig, sonst in eine eigene Python-Umgebung unter `/opt/certbot`),
2. prüft den Token direkt bei Cloudflare: gültig, Zone gefunden, darf DNS-Einträge anlegen
   und löschen – mit verständlicher Meldung, wenn etwas fehlt,
3. speichert den Token nur für root lesbar (`/root/.secrets/certbot/NAME.ini`, Rechte 600),
4. holt das Zertifikat,
5. richtet die automatische Erneuerung ein (systemd-Timer oder cron) und lädt den Webserver
   nach jeder Erneuerung neu,
6. testet die Erneuerung mit einem Probelauf.

Ein erneuter Aufruf ist gefahrlos: Ein vorhandenes Zertifikat wird nur erneuert, wenn es bald
abläuft oder Domains dazukommen.

Läuft auf Ubuntu 22.04/24.04, Debian 12/13, Fedora, Rocky Linux 9, AlmaLinux 9 und openSUSE
Leap/Tumbleweed (jede Version wird in der CI getestet).

## Den Cloudflare-Token anlegen

1. `https://dash.cloudflare.com/profile/api-tokens` öffnen → **Token erstellen**.
2. Vorlage **„Edit zone DNS“** (DNS-Zone bearbeiten) wählen.
3. Berechtigung: `Zone` → `DNS` → `Edit` (ist durch die Vorlage schon gesetzt).
4. Zonenressourcen: `Include` → `Specific zone` → die Zone, in der die Domain liegt.
5. Optional: unter **Client IP Address Filtering** nur die öffentliche Adresse des Servers
   zulassen. Bei Servern hinter NAT ist das die Adresse, mit der der Server ins Internet geht.
6. **Weiter zur Zusammenfassung** → **Token erstellen** → Token kopieren. Cloudflare zeigt
   ihn nur einmal an.

Ein „Global API Key“ funktioniert hier absichtlich nicht – er hätte Vollzugriff auf das ganze
Konto.

## Ohne Fragen (Automatisierung)

Ohne Terminal stellt das Skript keine Fragen; dann gelten nur die Optionen. Den Token am besten
aus einer Datei lesen lassen – dann steht er weder in der Shell-History noch in `ps`:

```bash
sudo install -m 600 /dev/null /root/cf-token && sudo nano /root/cf-token   # Token einfügen
curl -fsSL https://raw.githubusercontent.com/zerox80/certbot-sexy/main/zertifikat-cloudflare.sh \
  | sudo bash -s -- -d example.org -d '*.example.org' --token-file /root/cf-token --yes
sudo rm /root/cf-token   # das Skript hat den Token gespeichert
```

Alternativ liest es die Umgebungsvariable `CLOUDFLARE_API_TOKEN`. Ist für das Zertifikat schon
ein Token gespeichert, nimmt es diesen.

## Optionen

Mit `curl … | sudo bash -s -- OPTIONEN` oder nach dem Herunterladen mit
`sudo bash zertifikat-cloudflare.sh OPTIONEN`.

| Option | Bedeutung |
|---|---|
| `-d`, `--domain NAME` | Domain, mehrfach möglich, auch `*.example.org`. Ohne Terminal Pflicht. |
| `-n`, `--name NAME` | Name des Zertifikats (Ordner unter `/etc/letsencrypt/live/`). Standard: erste Domain ohne `*.` |
| `-m`, `--email ADRESSE` | Kontaktadresse für das Let's-Encrypt-Konto, freiwillig |
| `--token-file DATEI` | Token aus einer Datei lesen (nur der Token oder `dns_cloudflare_api_token = …`) |
| `--reload BEFEHL` | Nach jeder Erneuerung ausführen. Standard: Nginx, Apache oder HAProxy neu laden, wenn installiert |
| `--no-reload` | Nach einer Erneuerung nichts ausführen |
| `--key-type ecdsa\|rsa` | Schlüsseltyp, Standard `ecdsa` |
| `--propagation SEK` | Wartezeit für die Verteilung des TXT-Eintrags, Standard 30 |
| `--staging` | Test-Zertifikat aus der Staging-Umgebung (ohne Ratenlimits, nicht vertrauenswürdig) |
| `--dry-run` | Alles prüfen und die Challenge durchspielen, nichts speichern |
| `--force` | Sofort neu ausstellen, auch wenn das Zertifikat noch lange gilt |
| `--no-install` | Keine Pakete installieren |
| `-y`, `--yes` | Ohne Rückfrage ausführen |
| `--status` | Zertifikate, Ablaufdaten und automatische Erneuerung anzeigen |
| `--update-token` | Gespeicherten Token ersetzen (bei mehreren Zertifikaten mit `-n NAME`) |
| `--remove NAME` | Zertifikat und gespeicherten Token löschen |

## Wo liegt was

| Was | Wo |
|---|---|
| Zertifikat mit Zwischenzertifikat | `/etc/letsencrypt/live/NAME/fullchain.pem` |
| Privater Schlüssel | `/etc/letsencrypt/live/NAME/privkey.pem` |
| Cloudflare-Token | `/root/.secrets/certbot/NAME.ini` (nur root, 600) |
| Einstellungen für die Erneuerung | `/etc/letsencrypt/renewal/NAME.conf` |
| Protokoll von certbot | `/var/log/letsencrypt/letsencrypt.log` |

## Im Webserver einbinden

Nginx:

```nginx
ssl_certificate     /etc/letsencrypt/live/example.org/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/example.org/privkey.pem;
```

Apache:

```apache
SSLCertificateFile    /etc/letsencrypt/live/example.org/fullchain.pem
SSLCertificateKeyFile /etc/letsencrypt/live/example.org/privkey.pem
```

Danach `sudo nginx -t && sudo systemctl reload nginx` bzw. `sudo apachectl configtest && sudo systemctl reload apache2`.

## Automatische Erneuerung

- Debian und Ubuntu: `certbot.timer` aus dem Paket, Fedora und EPEL: `certbot-renew.timer` –
  das Skript schaltet ihn ein, falls er aus ist.
- Ohne passenden Timer (z. B. certbot in `/opt/certbot`) legt es `certbot-erneuern.timer` an.
- Ohne systemd (Container) nutzt es cron.

Der Timer prüft zweimal täglich; certbot erneuert erst, wenn das Zertifikat bald abläuft (bei
90 Tagen Laufzeit etwa 30 Tage vorher). Nach einer Erneuerung lädt der gespeicherte Befehl den
Webserver neu – der übernimmt das neue Zertifikat ohne Unterbrechung.

Let's Encrypt verschickt seit 2025 keine Erinnerungsmails vor dem Ablauf mehr. Wer sicher sein
will, prüft ab und zu den Status:

```bash
curl -fsSL https://raw.githubusercontent.com/zerox80/certbot-sexy/main/zertifikat-cloudflare.sh | sudo bash -s -- --status
```

## Sicherheit

- Der Token braucht nur „Zone → DNS → Bearbeiten“ für die eine Zone.
- Er wird nie auf der Befehlszeile übergeben (nicht in `ps` sichtbar) und nie ausgegeben.
- Die Token-Datei gehört root und hat die Rechte 600, der Ordner 700.
- Wer verhindern will, dass andere Zertifizierungsstellen Zertifikate für die Domain ausstellen,
  legt bei Cloudflare einen CAA-Eintrag an: `example.org CAA 0 issue "letsencrypt.org"`.
- Das Skript läuft als root. Wer es vorher lesen will:
  `curl -fsSLO https://raw.githubusercontent.com/zerox80/certbot-sexy/main/zertifikat-cloudflare.sh`,
  ansehen, dann `sudo bash zertifikat-cloudflare.sh`.

## Wenn etwas nicht klappt

| Meldung | Ursache und Lösung |
|---|---|
| „Cloudflare lehnt den Token ab“ | Token unvollständig kopiert, abgelaufen oder gelöscht – neuen anlegen |
| „findet der Token keine Zone“ | Domain liegt nicht bei Cloudflare, oder der Token gilt für eine andere Zone |
| „darf … keine DNS-Einträge anlegen“ | Token hat nur Leserechte – Recht „Zone → DNS → Bearbeiten“ ergänzen |
| „Cloudflare ist nicht erreichbar“ | Ausgehendes HTTPS zu `api.cloudflare.com` in der Firewall erlauben |
| certbot: „too many certificates“ | Ratenlimit von Let's Encrypt – zum Ausprobieren `--staging` nehmen |
| certbot: „Incorrect TXT record“ | Verteilung zu langsam – mit `--propagation 60` erneut versuchen |
| certbot: „CAA record … prevents issuance“ | CAA-Eintrag der Domain erlaubt Let's Encrypt nicht |

## Tests

Die CI testet bei jedem Push:

- ShellCheck für alle Skripte,
- jede unterstützte Distribution in einem frischen Container: echte Installation von certbot und
  dem Cloudflare-Plugin, Prüfung aller verwendeten certbot-Optionen gegen die installierte
  Version, alle Abläufe und Fehlerfälle, Rechte der Token-Datei, Fragerunde in einem simulierten
  Terminal (auch über `curl … | bash`) und dass der Token nie in der Ausgabe steht –
  Cloudflare-API und Let's Encrypt sind dabei Attrappen,
- Ende-zu-Ende auf Ubuntu mit systemd: die Erneuerungs-Timer werden wirklich aktiviert.

Lokal: `docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash /src/tests/container.sh`

## Lizenz

Apache-2.0, siehe [LICENSE](LICENSE).

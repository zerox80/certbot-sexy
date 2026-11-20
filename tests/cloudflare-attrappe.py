"""Attrappe der Cloudflare-API für die Tests – lauscht nur auf 127.0.0.1.

Gültige Tokens: GUT und GUT2 (dürfen DNS schreiben), NUR_LESEN (darf Zonen sehen, nicht schreiben).
Bekannte Zone: example.org. Jeder Aufruf landet in /tmp/cloudflare-aufrufe.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

GUT = "test_token_mit_schreibrecht_0123456789"
GUT2 = "test_token_zweiter_mit_schreibrecht_42"
NUR_LESEN = "test_token_nur_lesen_0123456789abcdef"
ZONEN = {"example.org": "zone-example-org"}
PROTOKOLL = "/tmp/cloudflare-aufrufe"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _token(self):
        auth = self.headers.get("Authorization", "")
        return auth[7:] if auth.startswith("Bearer ") else ""

    def _start(self):
        with open(PROTOKOLL, "a") as f:
            f.write("%s %s\n" % (self.command, self.path))
        if self._token() not in (GUT, GUT2, NUR_LESEN):
            self._send(403, {"success": False, "errors": [{"code": 9109, "message": "Invalid access token"}]})
            return False
        return True

    def do_GET(self):
        if not self._start():
            return
        url = urlparse(self.path)
        if url.path.endswith("/zones"):
            name = parse_qs(url.query).get("name", [""])[0]
            result = [{"id": ZONEN[name], "name": name}] if name in ZONEN else []
            self._send(200, {"success": True, "result": result})
            return
        self._send(404, {"success": False, "errors": [{"code": 7003, "message": "Not found"}]})

    def do_POST(self):
        if not self._start():
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length).decode() or "{}")
        if self._token() == NUR_LESEN:
            self._send(403, {"success": False, "errors": [{"code": 10000, "message": "Authentication error"}]})
            return
        self._send(200, {"success": True, "result": {"id": "eintrag-1", "name": body.get("name")}})

    def do_DELETE(self):
        if not self._start():
            return
        self._send(200, {"success": True, "result": {"id": "eintrag-1"}})

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()

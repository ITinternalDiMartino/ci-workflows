"""Server HTTP locale con risposte programmate, per la suite dello smoke test.

Uso: python3 -I http-server.py <routes.json> <port-file> <request-log> [<cert> <key>]

routes.json associa a ogni percorso una sequenza di risposte, consumate una per
richiesta; l'ultima si ripete. Ogni risposta è un oggetto:

    {"status": 200, "body": "testo", "headers": {"Location": "..."}}
    {"drop": true}       chiude la connessione senza rispondere (curl: 000)

Nei valori delle intestazioni, {port} diventa la porta del server.

Un percorso assente risponde 404. Il server scrive la porta scelta in
<port-file> quando è pronto, e una riga per richiesta in <request-log>.

Con certificato e chiave, la stessa porta risponde anche in HTTPS: così un
redirect da http:// a https:// resta sullo stesso host e sulla stessa porta,
come quello di un dominio che forza HTTPS. Una rotta "https /percorso" vale
solo per le richieste HTTPS e prevale su "/percorso". Nel registro le richieste
HTTPS hanno lo stesso prefisso "https ".
"""

import json
import os
import socket
import ssl
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

routes_file, port_file, log_file = sys.argv[1:4]

tls = None
if len(sys.argv) >= 6:
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(sys.argv[4], sys.argv[5])

with open(routes_file, encoding="utf-8") as f:
    routes = json.load(f)

served = {}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        scheme = "https " if isinstance(self.connection, ssl.SSLSocket) else ""
        with open(log_file, "a", encoding="utf-8") as log:
            log.write(scheme + path + "\n")

        key = scheme + path if scheme + path in routes else path
        sequence = routes.get(key)
        if not sequence:
            response = {"status": 404, "body": "<html><body>404 Not Found</body></html>"}
        else:
            index = served.get(key, 0)
            response = sequence[min(index, len(sequence) - 1)]
            served[key] = index + 1

        if response.get("drop"):
            self.connection.shutdown(socket.SHUT_RDWR)
            self.close_connection = True
            return

        body = response.get("body", "").encode("utf-8")
        self.send_response(response.get("status", 200))
        for name, value in response.get("headers", {}).items():
            self.send_header(name, value.replace("{port}", str(self.server.server_address[1])))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Server(HTTPServer):
    # Un ClientHello TLS comincia con il byte 0x16: si guarda il primo byte
    # senza consumarlo e si decide se avvolgere la connessione in TLS.
    def get_request(self):
        sock, addr = self.socket.accept()
        if tls is not None and sock.recv(1, socket.MSG_PEEK) == b"\x16":
            sock = tls.wrap_socket(sock, server_side=True)
        return sock, addr


server = Server(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
# rename: chi aspetta il file non legge mai una porta scritta a metà
os.replace(port_file + ".tmp", port_file)
server.serve_forever()

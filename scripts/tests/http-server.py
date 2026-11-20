"""Server HTTP locale con risposte programmate, per la suite dello smoke test.

Uso: python3 -I http-server.py <routes.json> <port-file> <request-log>

routes.json associa a ogni percorso una sequenza di risposte, consumate una per
richiesta; l'ultima si ripete. Ogni risposta è un oggetto:

    {"status": 200, "body": "testo", "headers": {"Location": "..."}}
    {"drop": true}       chiude la connessione senza rispondere (curl: 000)

Un percorso assente risponde 404. Il server scrive la porta scelta in
<port-file> quando è pronto, e una riga per richiesta in <request-log>.
"""

import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

routes_file, port_file, log_file = sys.argv[1:4]

with open(routes_file, encoding="utf-8") as f:
    routes = json.load(f)

served = {}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        with open(log_file, "a", encoding="utf-8") as log:
            log.write(path + "\n")

        sequence = routes.get(path)
        if not sequence:
            response = {"status": 404, "body": "<html><body>404 Not Found</body></html>"}
        else:
            index = served.get(path, 0)
            response = sequence[min(index, len(sequence) - 1)]
            served[path] = index + 1

        if response.get("drop"):
            self.connection.shutdown(socket.SHUT_RDWR)
            self.close_connection = True
            return

        body = response.get("body", "").encode("utf-8")
        self.send_response(response.get("status", 200))
        for name, value in response.get("headers", {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
# rename: chi aspetta il file non legge mai una porta scritta a metà
os.replace(port_file + ".tmp", port_file)
server.serve_forever()

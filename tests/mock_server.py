#!/usr/bin/env python3
"""Local stand-in for the release bucket, used only by tests/run.sh.

Serves a directory over HTTP on 127.0.0.1 with byte-range support, logs every
request, and can cut the first full download of chosen paths half way through
to simulate a dropped connection.

usage: mock_server.py <root> <port-file> <log-file> [cut-paths] [stall-paths]
Both path lists are comma separated. A cut path drops the connection after 40%
of its first full download; a stall path sends 40% and then goes silent.
"""
import http.server
import os
import sys
import time

ROOT, PORT_FILE, LOG_FILE = sys.argv[1], sys.argv[2], sys.argv[3]
CUT = set(filter(None, (sys.argv[4] if len(sys.argv) > 4 else "").split(",")))
STALL = set(filter(None, (sys.argv[5] if len(sys.argv) > 5 else "").split(",")))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        rng = self.headers.get("Range", "")
        with open(LOG_FILE, "a") as log:
            log.write(f"GET {self.path} {rng}\n")
        path = os.path.normpath(os.path.join(ROOT, self.path.lstrip("/")))
        if not path.startswith(os.path.abspath(ROOT)) or not os.path.isfile(path):
            self.send_error(404)
            return
        data = open(path, "rb").read()
        start = 0
        if rng.startswith("bytes="):
            start = int(rng[6:].split("-")[0] or 0)
            if start >= len(data):
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(data)}")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
        else:
            self.send_response(200)
        body = data[start:]
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        if self.path in CUT and start == 0:
            CUT.discard(self.path)
            self.wfile.write(body[: len(body) * 2 // 5])
            self.wfile.flush()
            self.close_connection = True
            return
        if self.path in STALL and start == 0:
            STALL.discard(self.path)
            self.wfile.write(body[: len(body) * 2 // 5])
            self.wfile.flush()
            time.sleep(15)
            self.close_connection = True
            return
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()

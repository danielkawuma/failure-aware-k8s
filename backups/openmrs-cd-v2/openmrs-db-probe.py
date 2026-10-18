#!/usr/bin/env python3
"""Independent TCP availability observation. Not a SQL or write-authority test."""
import argparse
import http.server
import socket
import time

p = argparse.ArgumentParser()
p.add_argument('--host', default='10.43.165.41')
p.add_argument('--port', type=int, default=3306)
p.add_argument('--listen', default='127.0.0.1')
p.add_argument('--http-port', type=int, default=18086)
p.add_argument('--timeout', type=float, default=1.5)
a = p.parse_args()
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/health':
            self.send_error(404)
            return
        start = time.monotonic()
        try:
            with socket.create_connection((a.host, a.port), a.timeout):
                pass
            status, payload = 200, b'DB_TCP_REACHABLE\n'
        except OSError:
            status, payload = 503, b'DB_TCP_UNREACHABLE\n'
        self.send_response(status)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, fmt, *args):
        print('%s %s' % (self.log_date_time_string(), fmt % args), flush=True)
server = http.server.ThreadingHTTPServer((a.listen, a.http_port), Handler)
print(f'Probe listening on {a.listen}:{a.http_port}, target={a.host}:{a.port}', flush=True)
server.serve_forever()

#!/usr/bin/env python3
"""Pinned original-Pod TCP probe via an independent SSH worker.
UNKNOWN is deliberately HTTP 200 to the legacy binary HTTP controller (PRESERVE),
while /state exposes UNKNOWN so the pilot aborts rather than treating it as a failure.
"""
import argparse
import http.server
import ipaddress
import json
import os
import shlex
import subprocess
import threading


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--host', required=True, help='Original MariaDB Pod IP captured before fault')
    p.add_argument('--port', type=int, default=int(os.getenv('OPENMRS_DB_PORT', '3306')))
    p.add_argument('--verifier-host', required=True, help='Independent worker SSH host/IP')
    p.add_argument('--ssh-user', default=os.getenv('OPENMRS_CD_SSH_USER', 'ubuntu'))
    p.add_argument('--ssh-key', default=os.getenv('SSH_KEY', os.path.expanduser('~/.ssh/k8s-aware')))
    p.add_argument('--listen', default='127.0.0.1')
    p.add_argument('--http-port', type=int, default=int(os.getenv('OPENMRS_DB_PROBE_HTTP_PORT', '18086')))
    p.add_argument('--tcp-timeout', type=float, default=2.0)
    p.add_argument('--ssh-timeout', type=float, default=8.0)
    a = p.parse_args()
    ipaddress.ip_address(a.host)
    if not 1 <= a.port <= 65535 or not 1 <= a.http_port <= 65535:
        p.error('invalid port')
    if not a.verifier_host or a.ssh_timeout <= a.tcp_timeout:
        p.error('invalid verifier host or timeouts')

    # Remote Python reports explicit states. An SSH transport failure is UNKNOWN.
    code = """import socket, sys
s = socket.socket()
s.settimeout(float(sys.argv[3]))
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    print('REACHABLE')
except OSError:
    print('UNREACHABLE')
finally:
    s.close()
"""
    remote = 'python3 -c ' + shlex.quote(code) + ' ' + ' '.join(
        shlex.quote(str(x)) for x in (a.host, a.port, a.tcp_timeout))
    ssh_cmd = ['ssh', '-i', a.ssh_key, '-o', 'BatchMode=yes',
               '-o', 'ConnectTimeout=4', '-o', 'ServerAliveInterval=2',
               '-o', 'ServerAliveCountMax=2',
               f'{a.ssh_user}@{a.verifier_host}', remote]

    def check():
        try:
            r = subprocess.run(ssh_cmd, text=True, capture_output=True,
                               timeout=a.ssh_timeout, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return 'UNKNOWN'
        if r.returncode != 0:
            return 'UNKNOWN'
        value = r.stdout.strip()
        return value if value in ('REACHABLE', 'UNREACHABLE') else 'UNKNOWN'

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ('/health', '/state'):
                self.send_error(404)
                return
            state = check()
            if self.path == '/state':
                body = json.dumps({'state': state, 'original_pod_ip': a.host,
                                   'verifier_host': a.verifier_host}).encode() + b'\n'
                status = 200
                content_type = 'application/json'
            else:
                # Legacy controller sees HTTP failure only on confirmed UNREACHABLE.
                status = 503 if state == 'UNREACHABLE' else 200
                body = (state + '\n').encode()
                content_type = 'text/plain'
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            print('probe state=' + state, flush=True)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer((a.listen, a.http_port), Handler)
    print(f'Probe original={a.host}:{a.port} verifier={a.ssh_user}@{a.verifier_host} adapter={a.listen}:{a.http_port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()

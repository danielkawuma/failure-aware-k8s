#!/usr/bin/env python3
"""Verify the selected replacement MariaDB Pod via SSH from an independent worker.
Never switches to the original node. /health returns 200 only on a successful TCP connection.
"""
import argparse
import http.server
import json
import os
import shlex
import subprocess


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--namespace', default=os.getenv('OPENMRS_CD_NAMESPACE', 'openmrs37'))
    p.add_argument('--selector', default=os.getenv('OPENMRS_CD_SELECTOR', 'app=openmrs-mariadb'))
    p.add_argument('--original-node', required=True)
    p.add_argument('--candidate-node', required=True)
    p.add_argument('--verifier-host', required=True)
    p.add_argument('--ssh-user', default=os.getenv('OPENMRS_CD_SSH_USER', 'ubuntu'))
    p.add_argument('--ssh-key', default=os.getenv('SSH_KEY', os.path.expanduser('~/.ssh/k8s-aware')))
    p.add_argument('--db-port', type=int, default=int(os.getenv('OPENMRS_DB_PORT', '3306')))
    p.add_argument('--http-port', type=int, default=int(os.getenv('OPENMRS_CD_RECOVERY_PROBE_PORT', '18087')))
    p.add_argument('--listen', default='127.0.0.1')
    a = p.parse_args()
    if a.original_node == a.candidate_node:
        p.error('original and candidate must differ')

    def check():
        try:
            result = subprocess.run(['kubectl', '--request-timeout=5s', 'get', 'pods', '-n', a.namespace,
                                     '-l', a.selector, '-o', 'json'], capture_output=True, text=True, timeout=8)
            if result.returncode != 0:
                return 'UNKNOWN', ''
            items = json.loads(result.stdout).get('items', [])
            ready = []
            for pod in items:
                if pod.get('spec', {}).get('nodeName') != a.candidate_node:
                    continue
                if pod.get('metadata', {}).get('deletionTimestamp') or pod.get('status', {}).get('phase') != 'Running':
                    continue
                conditions = pod.get('status', {}).get('conditions', [])
                if not any(c.get('type') == 'Ready' and c.get('status') == 'True' for c in conditions):
                    continue
                if pod.get('status', {}).get('podIP'):
                    ready.append(pod)
            if len(ready) != 1:
                return 'NOT_READY', ''
            ip = ready[0]['status']['podIP']
            code = ('import socket,sys; s=socket.socket(); s.settimeout(2); '
                    's.connect((sys.argv[1],int(sys.argv[2]))); s.close(); print("CONNECTED")')
            command = 'python3 -c ' + shlex.quote(code) + ' ' + shlex.quote(ip) + ' ' + str(a.db_port)
            ssh = subprocess.run(['ssh', '-i', a.ssh_key, '-o', 'BatchMode=yes',
                                  '-o', 'ConnectTimeout=4', '-o', 'ServerAliveInterval=2',
                                  '-o', 'ServerAliveCountMax=2', f'{a.ssh_user}@{a.verifier_host}', command],
                                 capture_output=True, text=True, timeout=10)
            if ssh.returncode == 0 and ssh.stdout.strip() == 'CONNECTED':
                return 'REACHABLE', ip
            return 'UNKNOWN', ip
        except (OSError, ValueError, subprocess.TimeoutExpired, KeyError):
            return 'UNKNOWN', ''

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ('/health', '/state'):
                self.send_error(404)
                return
            state, ip = check()
            if self.path == '/state':
                body = json.dumps({'state': state, 'replacement_pod_ip': ip,
                                   'candidate': a.candidate_node}).encode() + b'\n'
                status, content_type = 200, 'application/json'
            else:
                body = (state + '\n').encode()
                status, content_type = (200 if state == 'REACHABLE' else 503), 'text/plain'
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            print('recovery probe state=' + state + ' pod=' + ip, flush=True)

        def log_message(self, *_):
            pass

    print(f'Recovery probe candidate={a.candidate_node} verifier={a.verifier_host} port={a.http_port}', flush=True)
    http.server.ThreadingHTTPServer((a.listen, a.http_port), Handler).serve_forever()


if __name__ == '__main__':
    main()

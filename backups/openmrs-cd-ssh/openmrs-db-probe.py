#!/usr/bin/env python3
"""HTTP adapter for an independent TCP/3306 probe of the ORIGINAL database Pod.
A 200 means TCP connected; it does not establish SQL health or writer authority.
"""
import argparse
import http.server
import ipaddress
import json
import os
import socket
import subprocess


def kubectl_json(*args):
    return json.loads(subprocess.check_output(['kubectl', *args, '-o', 'json'], text=True, timeout=12))


def discover(namespace, selector, expected_node):
    pods = kubectl_json('get', 'pods', '-n', namespace, '-l', selector)['items']
    active = [p for p in pods if p['status'].get('phase') == 'Running'
              and not p['metadata'].get('deletionTimestamp')]
    if len(active) != 1:
        raise RuntimeError('Expected exactly one running original database Pod')
    pod = active[0]
    if expected_node and pod['spec'].get('nodeName') != expected_node:
        raise RuntimeError('Original database Pod is not on expected node')
    address = pod['status'].get('podIP')
    ipaddress.ip_address(address)
    return address, pod['metadata']['name']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--namespace', default=os.getenv('OPENMRS_CD_NAMESPACE', 'openmrs37'))
    parser.add_argument('--selector', default=os.getenv('OPENMRS_CD_SELECTOR', 'app=openmrs-mariadb'))
    parser.add_argument('--expected-node', default=os.getenv('OPENMRS_CD_ORIGINAL_NODE', ''))
    parser.add_argument('--host', default=os.getenv('OPENMRS_DB_HOST'))
    parser.add_argument('--port', type=int, default=int(os.getenv('OPENMRS_DB_PORT', '3306')))
    parser.add_argument('--listen', default=os.getenv('OPENMRS_DB_PROBE_LISTEN', '127.0.0.1'))
    parser.add_argument('--http-port', type=int, default=int(os.getenv('OPENMRS_DB_PROBE_HTTP_PORT', '18086')))
    parser.add_argument('--timeout', type=float, default=1.5)
    args = parser.parse_args()
    if args.host:
        ipaddress.ip_address(args.host)
        host = args.host
        pod_name = 'explicit-original-pod'
    else:
        host, pod_name = discover(args.namespace, args.selector, args.expected_node)
    if not (0 < args.port < 65536 and 0 < args.http_port < 65536):
        parser.error('Invalid port')

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/health':
                self.send_error(404)
                return
            try:
                with socket.create_connection((host, args.port), args.timeout):
                    pass
                code, payload = 200, b'DB_TCP_REACHABLE\n'
            except OSError:
                code, payload = 503, b'DB_TCP_UNREACHABLE\n'
            self.send_response(code)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, fmt, *values):
            print('%s %s' % (self.log_date_time_string(), fmt % values), flush=True)

    server = http.server.ThreadingHTTPServer((args.listen, args.http_port), Handler)
    print(f'Original database: {pod_name} {host}:{args.port}; adapter: {args.listen}:{args.http_port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()

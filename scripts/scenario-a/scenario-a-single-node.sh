#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/experiment-config.sh"

ACTION="${1:-status}"

case "$ACTION" in
  install)
    ssh -i "$SSH_KEY" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      "$WORKER1_SSH" \
      'sudo -n bash -s' <<'REMOTE'
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y nginx

cat > /etc/nginx/sites-available/scenario-a <<'NGINX'
server {
    listen 8081 default_server;
    listen [::]:8081 default_server;

    server_name _;

    location / {
        default_type text/plain;
        return 200 "SCENARIO_A_STANDALONE_NGINX\n";
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sfn \
  /etc/nginx/sites-available/scenario-a \
  /etc/nginx/sites-enabled/scenario-a

nginx -t
systemctl enable nginx
systemctl restart nginx

curl --fail --silent \
  http://127.0.0.1:8081/
REMOTE
    ;;

  status)
    curl --fail --silent \
      --connect-timeout 3 \
      --max-time 5 \
      "http://${WORKER1_IP}:8081/"
    ;;

  *)
    echo "Usage: $0 install|status"
    exit 2
    ;;
esac

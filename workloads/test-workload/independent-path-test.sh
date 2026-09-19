while true; do
    date '+%Y-%m-%dT%H:%M:%S.%3N'
    curl -s -o /dev/null \
      -w 'HTTP=%{http_code} time=%{time_total}s\n' \
      http://102.34.160.87:30364 # This is the IP for k3s-worker1 and the NodePort for the service is 30364.
    sleep 1
done
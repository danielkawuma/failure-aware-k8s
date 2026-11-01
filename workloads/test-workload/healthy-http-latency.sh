for i in $(seq 1 100); do
    curl -s -o /dev/null \
      -w '%{time_total}\n' \
      http://10.10.0.11:30364 # This is the IP for k3s-worker1 and the NodePort for the service is 30364.
    sleep 0.1
done > baseline-http-latency.txt
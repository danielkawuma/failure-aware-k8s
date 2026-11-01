#!/bin/sh

URL="http://10.10.0.11:30364"

while true; do

    TIMESTAMP=$(date '+%d %B %Y %H:%M:%S.%3N')

    RESULT=$(curl -s -o /dev/null \
        -w 'HTTP=%{http_code} latency=%{time_total}s' \
        "$URL")

    echo "$TIMESTAMP | $RESULT"

    sleep 1
done
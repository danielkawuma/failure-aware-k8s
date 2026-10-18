#!/usr/bin/env python3

import argparse
import csv
import datetime
import time
import urllib.error
import urllib.request


def utc_now():
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument("--url", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--timeout", type=float, default=3.0)
    parser.add_argument("--expected-body", default="")

    args = parser.parse_args()

    with open(args.output, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "timestamp_utc",
                "status",
                "success",
                "latency_ms",
                "error",
            ],
        )

        writer.writeheader()
        f.flush()

        while True:
            timestamp = utc_now()
            started = time.monotonic()

            status = 0
            success = False
            error = ""

            try:
                with urllib.request.urlopen(
                    args.url,
                    timeout=args.timeout,
                ) as response:
                    status = response.status
                    body = response.read(4096).decode(
                        "utf-8", errors="replace"
                    )

                    success = (
                        status == 200
                        and (
                            not args.expected_body
                            or args.expected_body in body
                        )
                    )

                    if not success:
                        error = "Unexpected status or response body"

            except Exception as exc:
                error = str(exc)

            latency = (time.monotonic() - started) * 1000

            writer.writerow({
                "timestamp_utc": timestamp,
                "status": status,
                "success": str(success).lower(),
                "latency_ms": round(latency, 3),
                "error": error,
            })

            f.flush()
            time.sleep(args.interval)


if __name__ == "__main__":
    main()

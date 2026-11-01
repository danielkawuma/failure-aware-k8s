#!/usr/bin/env python3
"""Clinical load generator for OpenMRS (standard library only).

Each virtual user repeats a short clinical sequence against the OpenMRS
REST API through the gateway: open a session, search patients, list
encounters of a patient, list locations. Every request is written to a
CSV with its UTC time, operation, HTTP status, latency and success, so
the load can be lined up with fault windows afterwards.

Environment:
  OPENMRS_BASE_URL   e.g. http://<worker2-ip>:30366/openmrs
  OPENMRS_USER / OPENMRS_PASS   credentials (never committed)
  LOAD_USERS         virtual users (default 10)
  LOAD_THINK_SECONDS pause between requests per user (default 1.0)
  LOAD_TIMEOUT       per-request timeout in seconds (default 10)
  LOAD_OUT           output CSV path
  LOAD_STOP_FILE     the generator stops when this file exists
"""
import base64, csv, json, os, random, threading, time, urllib.request, urllib.error
from datetime import datetime, timezone

BASE = os.environ["OPENMRS_BASE_URL"].rstrip("/")
AUTH = base64.b64encode(f'{os.environ["OPENMRS_USER"]}:{os.environ["OPENMRS_PASS"]}'.encode()).decode()
USERS = int(os.environ.get("LOAD_USERS", "10"))
THINK = float(os.environ.get("LOAD_THINK_SECONDS", "1.0"))
TIMEOUT = float(os.environ.get("LOAD_TIMEOUT", "10"))
OUT = os.environ.get("LOAD_OUT", "openmrs-load.csv")
STOP = os.environ.get("LOAD_STOP_FILE", OUT + ".stop")
lock = threading.Lock()
f = open(OUT, "a", newline="")
w = csv.writer(f, lineterminator="\n")
if f.tell() == 0:
    w.writerow(["utc", "vu", "op", "status", "latency_ms", "ok"])


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def call(vu, op, path):
    req = urllib.request.Request(BASE + "/ws/rest/v1/" + path,
                                 headers={"Authorization": "Basic " + AUTH, "Accept": "application/json"})
    t0 = time.monotonic(); status = 0; body = None
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            status = r.status; body = r.read()
    except urllib.error.HTTPError as e:
        status = e.code
    except Exception:
        status = 0
    ms = (time.monotonic() - t0) * 1000
    ok = 200 <= status < 300
    with lock:
        w.writerow([now(), vu, op, status, f"{ms:.1f}", int(ok)]); f.flush()
    return body if ok else None


def user(vu):
    rng = random.Random(vu)
    while not os.path.exists(STOP):
        call(vu, "session", "session")
        body = call(vu, "patient_search", f"patient?q={rng.choice('aeiou')}&limit=5")
        uuid = None
        if body:
            try:
                res = json.loads(body).get("results", [])
                uuid = res[0]["uuid"] if res else None
            except Exception:
                pass
        if uuid:
            call(vu, "encounters", f"encounter?patient={uuid}&limit=5")
        call(vu, "locations", "location?limit=5")
        time.sleep(THINK)


threads = [threading.Thread(target=user, args=(i,), daemon=True) for i in range(USERS)]
for t in threads:
    t.start(); time.sleep(0.2)
while not os.path.exists(STOP):
    time.sleep(1)
time.sleep(TIMEOUT + 1)
f.close()

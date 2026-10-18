#!/usr/bin/env python3
"""Idempotent synthetic OpenMRS clinical-data seeder."""

import argparse
import base64
import getpass
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

VISIT_FACILITY = "7b0f5697-27e3-40c4-8bae-f4049abfb4ed"
VISIT_OPD = "287463d3-2233-4c69-9851-5841a1f5e109"

LOCATION_OPD = "44c3efb0-2583-4c80-a79e-1f756a03c0a1"
LOCATION_INPATIENT = "ba685651-ed3b-4e63-9b35-78893060758a"

ENCOUNTER_VITALS = "67a71486-1a54-468f-ac3e-7091a9a79584"
ENCOUNTER_ADMISSION = "e22e39fd-7db2-45e7-80f1-60fa0d5a4378"

CONCEPT_TEMP = "5088AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

SEED_DAY = datetime(2026, 10, 8, 7, 0, tzinfo=timezone.utc)

class API:
    def __init__(self, base, username, password):
        self.base = base.rstrip("/") + "/ws/rest/v1/"
        auth = base64.b64encode(
            f"{username}:{password}".encode()
        ).decode()
        self.headers = {
            "Authorization": "Basic " + auth,
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    def call(self, method, path, payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(
            self.base + path,
            data=data,
            headers=self.headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=45) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            raise RuntimeError(
                f"{method} {path}: HTTP {exc.code}: {body[:500]}"
            ) from exc

    def pages(self, resource, params):
        offset = 0
        while True:
            query = dict(params, limit=100, startIndex=offset)
            page = self.call(
                "GET", resource + "?" + urllib.parse.urlencode(query)
            )
            records = page.get("results", [])
            yield from records
            if len(records) < 100 or not any(
                x.get("rel") == "next" for x in page.get("links", [])
            ):
                return
            offset += len(records)

def stamp(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000+0000")

def uuid_of(value):
    return value.get("uuid") if isinstance(value, dict) else value

def parse_date(value):
    return datetime.strptime(
        value[:19], "%Y-%m-%dT%H:%M:%S"
    ).replace(tzinfo=timezone.utc)

def matching_visit(visits, kind, location):
    return next(
        (
            v for v in visits
            if not v.get("voided")
            and uuid_of(v.get("visitType")) == kind
            and uuid_of(v.get("location")) == location
        ),
        None,
    )

def matching_encounter(encounters, kind, visit_uuid):
    return next(
        (
            e for e in encounters
            if not e.get("voided")
            and uuid_of(e.get("encounterType")) == kind
            and uuid_of(e.get("visit")) == visit_uuid
        ),
        None,
    )

def verify_vitals(api, encounter_uuid, expected):
    record = api.call("GET", f"encounter/{encounter_uuid}?v=full")
    for obs in record.get("obs", []):
        if obs.get("voided"):
            continue
        concept = uuid_of(obs.get("concept"))
        display = obs.get("display") or ""
        if concept != CONCEPT_TEMP and not display.startswith(
            "Temperature (c):"
        ):
            continue
        value = obs.get("value")
        if isinstance(value, (int, float)):
            if abs(float(value) - expected) < 0.001:
                return record
        if display.endswith(": " + str(expected)):
            return record
    raise RuntimeError(
        f"Temperature verification failed: {encounter_uuid}"
    )

def save_manifest(path, manifest):
    data = [manifest[k] for k in sorted(manifest)]
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--patients", type=Path,
        default=Path("experiments/openmrs-bootstrap/patients.json")
    )
    parser.add_argument(
        "--output", type=Path,
        default=Path("experiments/openmrs-bootstrap/clinical-data.json")
    )
    parser.add_argument(
        "--base",
        default=os.getenv(
            "OPENMRS_BASE_URL",
            "http://102.34.160.87:30366/openmrs"
        )
    )
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    patients = json.loads(args.patients.read_text())
    if len(patients) != 20 or len({
        p["experimental_id"] for p in patients
    }) != 20:
        raise RuntimeError("Expected 20 unique patients")

    username = os.getenv("OMRS_USER") or input("OpenMRS username: ")
    password = os.getenv("OMRS_PASS") or getpass.getpass(
        "OpenMRS password: "
    )

    api = API(args.base, username, password)
    if not api.call("GET", "session").get("authenticated"):
        raise RuntimeError("Authentication failed")

    args.output.parent.mkdir(parents=True, exist_ok=True)

    manifest = {}
    if args.output.exists():
        manifest = {
            p["experimental_id"]: p
            for p in json.loads(args.output.read_text())
        }

    for patient in sorted(
        patients, key=lambda p: p["experimental_id"]
    ):
        eid = patient["experimental_id"]
        patient_uuid = patient["uuid"]
        category = patient["category"]
        number = int(eid.rsplit("-", 1)[-1])

        location = (
            LOCATION_INPATIENT if category == "inpatient"
            else LOCATION_OPD
        )
        visit_type = (
            VISIT_OPD if category == "outpatient"
            else VISIT_FACILITY
        )

        if number == 1:
            visit_type = VISIT_FACILITY

        temp = (
            36.8 if number == 1
            else round(36.4 + (number % 11) * 0.1, 1)
        )

        day = SEED_DAY + timedelta(minutes=number)

        print(f"{eid}: {category}", flush=True)

        visits = list(api.pages(
            "visit", {"patient": patient_uuid, "v": "full"}
        ))

        visit = matching_visit(visits, visit_type, location)

        if not visit:
            if not args.apply:
                print("  PLAN create visit")
                continue

            visit = api.call("POST", "visit", {
                "patient": patient_uuid,
                "visitType": visit_type,
                "location": location,
                "startDatetime": stamp(day),
            })
            print("  created visit", visit["uuid"])
        else:
            print("  existing visit", visit["uuid"])

        visit_uuid = visit["uuid"]
        visit_start = parse_date(visit["startDatetime"])

        encounters = list(api.pages(
            "encounter", {"patient": patient_uuid, "v": "full"}
        ))

        vitals = matching_encounter(
            encounters, ENCOUNTER_VITALS, visit_uuid
        )

        if not vitals:
            if not args.apply:
                print("  PLAN create vitals")
                continue

            when = visit_start + timedelta(minutes=15)

            if when >= datetime.now(timezone.utc):
                when = datetime.now(timezone.utc) - timedelta(minutes=5)

            vitals = api.call("POST", "encounter", {
                "patient": patient_uuid,
                "visit": visit_uuid,
                "encounterType": ENCOUNTER_VITALS,
                "location": location,
                "encounterDatetime": stamp(when),
                "obs": [{
                    "concept": CONCEPT_TEMP,
                    "value": temp,
                    "obsDatetime": stamp(when),
                }],
            })
            print("  created vitals", vitals["uuid"])

        verified = verify_vitals(api, vitals["uuid"], temp)

        entry = {
            "experimental_id": eid,
            "patient_uuid": patient_uuid,
            "category": category,
            "visit_uuid": visit_uuid,
            "vitals_encounter_uuid": verified["uuid"],
            "temperature_c": temp,
        }

        if category == "inpatient":
            admission = matching_encounter(
                encounters, ENCOUNTER_ADMISSION, visit_uuid
            )

            if not admission:
                if not args.apply:
                    print("  PLAN create admission")
                else:
                    when = visit_start + timedelta(minutes=20)
                    now = datetime.now(timezone.utc)

                    if when >= now:
                        when = now - timedelta(minutes=2)

                    admission = api.call("POST", "encounter", {
                        "patient": patient_uuid,
                        "visit": visit_uuid,
                        "encounterType": ENCOUNTER_ADMISSION,
                        "location": location,
                        "encounterDatetime": stamp(when),
                    })
                    print(
                        "  created admission encounter",
                        admission["uuid"]
                    )

            if admission:
                confirmed = api.call(
                    "GET", f"encounter/{admission['uuid']}?v=full"
                )
                if uuid_of(confirmed.get("encounterType")) != ENCOUNTER_ADMISSION:
                    raise RuntimeError("Admission verification failed")
                entry["admission_encounter_uuid"] = confirmed["uuid"]

        manifest[eid] = entry

        if args.apply:
            save_manifest(args.output, manifest)

        print("  verified", flush=True)

    print()
    print("Finished. Recorded entries:", len(manifest))
    print("Mode:", "APPLY" if args.apply else "DRY RUN")

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("ERROR:", exc, file=sys.stderr)
        sys.exit(1)

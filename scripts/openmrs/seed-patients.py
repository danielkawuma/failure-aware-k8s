#!/usr/bin/env python3

import base64
import getpass
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE_URL = os.environ.get(
    "OPENMRS_BASE_URL",
    "http://102.34.160.87:30366/openmrs"
).rstrip("/")

SOURCE_UUID = "8549f706-7e85-4c1d-9424-217d50a2988b"
OPENMRS_ID_TYPE = "05a29f94-c0ed-11e2-94be-8c13b969e334"
EXPERIMENT_ID_TYPE = "b4143563-16cd-4439-b288-f83d61670fc8"

OUTPUT = Path("experiments/openmrs-bootstrap/patients.json")

PATIENTS = [
    {
        "number": i,
        "identifier": f"FA-EMR-{i:04d}",
        "givenName": "Test",
        "familyName": f"Patient{i:03d}",
        "gender": "F" if i % 2 else "M",
        "birthdate": f"{1980 + (i * 3) % 30}-"
                     f"{(i % 12) + 1:02d}-15",
        "category": (
            "outpatient" if i <= 8
            else "inpatient" if i <= 16
            else "emergency"
        )
    }
    for i in range(1, 21)
]


class OpenMRSClient:
    def __init__(self, username, password):
        credentials = base64.b64encode(
            f"{username}:{password}".encode()
        ).decode()

        self.headers = {
            "Authorization": f"Basic {credentials}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    def request(self, method, path, payload=None):
        data = None

        if payload is not None:
            data = json.dumps(payload).encode("utf-8")

        req = urllib.request.Request(
            f"{BASE_URL}/ws/rest/v1/{path}",
            data=data,
            headers=self.headers,
            method=method,
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"HTTP {exc.code}: {detail[:500]}"
            ) from exc

    def generate_identifier(self):
        result = self.request(
            "POST",
            f"idgen/identifiersource/{SOURCE_UUID}/identifier",
            {},
        )
        return result["identifier"]

    def find_patient(self, identifier):
        result = self.request(
            "GET",
            "patient?q=" + urllib.parse.quote(identifier),
        )

        for patient in result.get("results", []):
            full = self.request(
                "GET",
                f"patient/{patient['uuid']}?v=full",
            )

            for item in full.get("identifiers", []):
                if item.get("identifier") == identifier:
                    return full

        return None

    def create_patient(self, patient, openmrs_id):
        payload = {
            "person": {
                "names": [{
                    "givenName": patient["givenName"],
                    "familyName": patient["familyName"],
                }],
                "gender": patient["gender"],
                "birthdate": patient["birthdate"],
            },
            "identifiers": [
                {
                    "identifier": openmrs_id,
                    "identifierType": OPENMRS_ID_TYPE,
                    "preferred": True,
                },
                {
                    "identifier": patient["identifier"],
                    "identifierType": EXPERIMENT_ID_TYPE,
                    "preferred": False,
                },
            ],
        }

        return self.request("POST", "patient", payload)


def main():
    username = input("OpenMRS username: ")
    password = getpass.getpass("OpenMRS password: ")

    client = OpenMRSClient(username, password)

    session = client.request("GET", "session")

    if not session.get("authenticated"):
        raise RuntimeError("OpenMRS authentication failed")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    manifest = []

    for patient in PATIENTS:
        identifier = patient["identifier"]

        print(f"Processing {identifier}...", flush=True)

        existing = client.find_patient(identifier)

        if existing:
            record = existing
            status = "existing"
        else:
            openmrs_id = client.generate_identifier()
            record = client.create_patient(patient, openmrs_id)
            status = "created"

        uuid = record["uuid"]

        verified = client.request(
            "GET",
            f"patient/{uuid}?v=full",
        )

        identifiers = [
            x.get("identifier")
            for x in verified.get("identifiers", [])
        ]

        if identifier not in identifiers:
            raise RuntimeError(
                f"Verification failed for {identifier}"
            )

        manifest.append({
            "experimental_id": identifier,
            "uuid": uuid,
            "category": patient["category"],
            "status": status,
        })

        OUTPUT.write_text(
            json.dumps(manifest, indent=2),
            encoding="utf-8",
        )

        print(f"  {status}: {uuid}")

    print()
    print(f"Completed {len(manifest)} synthetic patients")
    print(f"Manifest: {OUTPUT}")


if __name__ == "__main__":
    main()
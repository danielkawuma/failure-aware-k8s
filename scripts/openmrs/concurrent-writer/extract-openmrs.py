#!/usr/bin/env python3

import gzip
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

SOURCE = (
    ROOT
    / "backups/mariadb"
    / "openmrs-mariadb-20261013T150125Z.sql.gz"
)

OUTPUT = (
    ROOT
    / "backups/mariadb"
    / "openmrs-concurrent-writer-application.sql"
)

USE_PATTERN = re.compile(
    r"^\s*USE\s+`?([A-Za-z0-9_]+)`?\s*;",
    re.IGNORECASE,
)

def main():
    if not SOURCE.is_file():
        raise SystemExit("Backup not found")

    if OUTPUT.exists():
        raise SystemExit(
            "Output already exists; refusing overwrite"
        )

    current_database = None
    sections = 0
    written = 0

    with gzip.open(
        SOURCE,
        "rt",
        encoding="utf-8",
        errors="strict",
    ) as source, OUTPUT.open(
        "w",
        encoding="utf-8",
    ) as output:

        output.write(
            "CREATE DATABASE IF NOT EXISTS `openmrs`;\n"
            "USE `openmrs`;\n"
        )

        for line in source:
            match = USE_PATTERN.match(line)

            if match:
                current_database = match.group(1).lower()

                if current_database == "openmrs":
                    sections += 1

                continue

            if current_database == "openmrs":
                output.write(line)
                written += 1

    if sections != 2 or written == 0:
        OUTPUT.unlink(missing_ok=True)
        raise SystemExit(
            "Unexpected database sections; extraction rejected"
        )

    print("OPENMRS_APPLICATION_DUMP_EXTRACTED")
    print("Sections:", sections)
    print("Lines:", written)
    print("Output:", OUTPUT)


if __name__ == "__main__":
    main()

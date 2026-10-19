#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT/openmrs/backend/run-openmrs-integrated.sh" "$@"

#!/usr/bin/env bash
exec "$(dirname "${BASH_SOURCE[0]}")/openmrs/database/openmrs-cd-placement-prepare.sh" "$@"

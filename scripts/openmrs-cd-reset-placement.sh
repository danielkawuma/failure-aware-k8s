#!/usr/bin/env bash
exec "$(dirname "${BASH_SOURCE[0]}")/openmrs/database/openmrs-cd-reset-placement.sh" "$@"

#!/usr/bin/env bash
exec "$(dirname "${BASH_SOURCE[0]}")/openmrs/backend/openmrs-backend-reset.sh" "$@"

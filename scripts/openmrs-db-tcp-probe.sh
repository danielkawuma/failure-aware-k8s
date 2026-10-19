#!/usr/bin/env bash
exec "$(dirname "${BASH_SOURCE[0]}")/openmrs/diagnostics/openmrs-db-tcp-probe.sh" "$@"

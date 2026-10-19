#!/usr/bin/env bash

# Scenario D configuration entry point.
# Source the scenario-specific configuration in the current shell.

source "$(
    cd "$(dirname "${BASH_SOURCE[0]}")" &&
    pwd
)/scenario-d/scenario-d-config.sh"

#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only original-writer diagnostics.
# Never unfences or deletes anything.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AUTHORITY_FILE="${1:?Usage: $0 /path/to/controller-authority.json}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/k8s-aware}"
SSH_USER="${OPENMRS_CD_SSH_USER:-ubuntu}"

[[ -r "$AUTHORITY_FILE" && -r "$SSH_KEY" ]] || {
    echo 'Missing authority file or SSH key' >&2
    exit 2
}

read -r ORIGINAL IP CANDIDATE ORIGINAL_POD < <(
python3 - "$AUTHORITY_FILE" <<'PY'
import json, ipaddress, re, sys

x = json.load(open(sys.argv[1]))
vals = [x[k] for k in ('node', 'ip', 'candidate', 'pod')]

assert all(isinstance(v, str) for v in vals)
assert all(
    re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', v)
    for v in (vals[0], vals[2], vals[3])
)

ipaddress.IPv4Address(vals[1])
assert vals[0] != vals[2]

print(*vals)
PY
)

export OPENMRS_CD_ORIGINAL_NODE="$ORIGINAL"
export OPENMRS_CD_ORIGINAL_IP="$IP"

echo "ORIGINAL=$ORIGINAL IP=$IP"
echo "CANDIDATE=$CANDIDATE ORIGINAL_POD=$ORIGINAL_POD"

echo '=== EXTERNAL FENCE STATUS ==='

set +e
FENCE_OUTPUT="$(
    "$ROOT/scripts/openmrs-cd-fence-original.sh" status 2>&1
)"
FENCE_RC=$?
set -e

printf '%s\n' "$FENCE_OUTPUT"

if [[ "$FENCE_RC" -ne 0 ]] ||
   ! grep -qx 'FENCED' <<< "$FENCE_OUTPUT"; then
    echo 'FENCE_NOT_VERIFIED; DO_NOT_UNFENCE' >&2
    exit 1
fi

echo 'FENCE_REPORTED_ACTIVE'
echo '=== ORIGINAL HOST PROCESS INSPECTION ==='

set +e

timeout 35 ssh \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=2 \
    "$SSH_USER@$IP" \
    'sudo -n python3 -' <<'PY'
import os
import sys

found = False

for item in os.listdir('/proc'):
    if not item.isdigit():
        continue

    pid = int(item)

    try:
        comm = open(f'/proc/{pid}/comm').read().strip()

        if comm not in ('mariadbd', 'mysqld'):
            continue

        stat = open(
            f'/proc/{pid}/stat'
        ).read().rsplit(') ', 1)[1].split()[0]

        if stat in ('Z', 'X', 'x'):
            continue

        found = True

        try:
            stack = open(f'/proc/{pid}/stack').read()
        except OSError:
            stack = ''

        if stat == 'D':
            exit_path = (
                'do_exit' in stack or 'exit_files' in stack
            )
            nfs_unlock = (
                'nfs4_proc_unlck' in stack
                or ('do_unlk' in stack and 'nfs' in stack)
            )

            classification = (
                'ORIGINAL_WRITER_EXIT_PENDING'
                if exit_path and nfs_unlock
                else 'ORIGINAL_WRITER_BLOCKED'
            )

            operation = (
                'NFS_LOCK_RELEASE'
                if nfs_unlock
                else 'UNCONFIRMED'
            )
        else:
            classification = 'ORIGINAL_WRITER_ACTIVE'
            operation = 'UNCONFIRMED'

        print(f'RUNTIME_CLASSIFICATION={classification}')
        print(
            f'PID={pid} PROCESS={comm} '
            f'STATE={stat} BLOCKED_OPERATION={operation}'
        )
        print('RECONCILIATION=BLOCKED FENCE=RETAIN')

    except (FileNotFoundError, ProcessLookupError):
        continue

    except (OSError, ValueError) as e:
        print(
            f'RUNTIME_INSPECTION_UNKNOWN={e}',
            file=sys.stderr
        )
        sys.exit(3)

if not found:
    print('RUNTIME_CLASSIFICATION=NO_MARIADB_PROCESS_OBSERVED')
    print('RECONCILIATION=AUTHORITY_PROOF_PENDING FENCE=RETAIN')
PY

REMOTE_RC=$?
set -e

if [[ "$REMOTE_RC" -ne 0 ]]; then
    echo "RUNTIME_INSPECTION_UNVERIFIED exit=$REMOTE_RC; FENCE=RETAIN" >&2
    exit 1
fi

echo 'DIAGNOSTIC_COMPLETE; FENCE=RETAIN; UNFENCE_NOT_AUTHORIZED'
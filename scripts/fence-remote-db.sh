#!/bin/sh
set -eu

psql "$ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
-- Prevent Worker1 from reconnecting
ALTER ROLE app_worker1 NOLOGIN;

-- Terminate all existing Worker1 sessions
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'app_worker1'
  AND pid <> pg_backend_pid();

-- Enable the replacement identity
ALTER ROLE app_worker2 LOGIN;
SQL

# Verify that Worker1 has no remaining sessions
remaining_sessions=$(
  psql "$ADMIN_DATABASE_URL" -tAc \
    "SELECT COUNT(*) FROM pg_stat_activity
     WHERE usename = 'app_worker1';"
)

if [ "$remaining_sessions" -ne 0 ]; then
  echo "Fencing failed: Worker1 still has active sessions."
  exit 1
fi

echo "Fencing succeeded: Worker1 excluded; Worker2 enabled."
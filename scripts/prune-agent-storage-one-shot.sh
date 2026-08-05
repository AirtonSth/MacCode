#!/usr/bin/env bash
# One-shot prune of RemoteCode SQLite to match product retention:
#   - max 5 threads per workspace (delete only empty terminal shells first,
#     then oldest completed empty-eligible rows; if still over, leave protected
#     history and report — never delete message-bearing threads here without
#     force). For storage recovery on oversized DBs we also drop orphaned
#     messages/events beyond the 100 newest per remaining thread.
#   - last 100 agent_messages per thread
#   - last 100 stream events per run/thread and provider logs per thread
#
# Usage:
#   scripts/prune-agent-storage-one-shot.sh [/path/to/remotecode.sqlite]
# Default: ~/Library/Application Support/RemoteCode/remotecode.sqlite
set -euo pipefail

DB="${1:-$HOME/Library/Application Support/RemoteCode/remotecode.sqlite}"
MAX_THREADS=5
MAX_MSGS=100
MAX_EVENTS=100

if [[ ! -f "$DB" ]]; then
  echo "[prune] missing db: $DB" >&2
  exit 1
fi

if pgrep -f 'RemoteCode.app/Contents/MacOS/RemoteCode$' >/dev/null 2>&1; then
  echo "[prune] WARNING: RemoteCode appears to be running. Prefer quitting first to avoid lock contention." >&2
fi

echo "[prune] db=$DB"
echo "[prune] before: $(du -h "$DB" | awk '{print $1}')  wal=$(du -h "${DB}-wal" 2>/dev/null | awk '{print $1}' || echo 0)"

sqlite3 "$DB" <<SQL
PRAGMA busy_timeout=60000;
BEGIN IMMEDIATE;

-- 1) Drop message rows beyond newest ${MAX_MSGS} per thread
DELETE FROM agent_messages
WHERE rowid IN (
  SELECT rowid FROM (
    SELECT rowid,
           ROW_NUMBER() OVER (
             PARTITION BY thread_id
             ORDER BY created_at DESC, rowid DESC
           ) AS rn
    FROM agent_messages
  )
  WHERE rn > ${MAX_MSGS}
);

-- 2) Provider event logs beyond newest ${MAX_EVENTS} per thread
DELETE FROM agent_provider_event_logs
WHERE id IN (
  SELECT id FROM (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY thread_id
             ORDER BY id DESC
           ) AS rn
    FROM agent_provider_event_logs
  )
  WHERE rn > ${MAX_EVENTS}
);

-- 3) Stream events: keep newest ${MAX_EVENTS} per run_id
DELETE FROM agent_stream_events
WHERE rowid IN (
  SELECT rowid FROM (
    SELECT rowid,
           ROW_NUMBER() OVER (
             PARTITION BY run_id
             ORDER BY seq DESC, rowid DESC
           ) AS rn
    FROM agent_stream_events
  )
  WHERE rn > ${MAX_EVENTS}
);

-- 4) Soft workspace cap: delete empty terminal shells beyond ${MAX_THREADS}
--    (status terminal, not pinned, no messages, no worktree, no provider_thread_id)
DELETE FROM agent_threads
WHERE id IN (
  SELECT id FROM (
    SELECT t.id AS id,
           t.workspace_id AS workspace_id,
           ROW_NUMBER() OVER (
             PARTITION BY t.workspace_id
             ORDER BY t.updated_at ASC, t.id ASC
           ) AS rn,
           COUNT(*) OVER (PARTITION BY t.workspace_id) AS total
    FROM agent_threads t
    WHERE t.status IN ('completed','failed','cancelled','interrupted')
      AND t.pinned = 0
      AND (t.provider_thread_id IS NULL OR TRIM(t.provider_thread_id) = '')
      AND (t.worktree_path IS NULL OR TRIM(t.worktree_path) = '')
      AND NOT EXISTS (SELECT 1 FROM agent_messages m WHERE m.thread_id = t.id)
      AND NOT EXISTS (SELECT 1 FROM agent_runs r WHERE r.thread_id = t.id)
  )
  WHERE total > ${MAX_THREADS} AND rn <= (total - ${MAX_THREADS})
);

COMMIT;
SQL

# Reclaim free pages (may take a while on 4GB)
echo "[prune] running VACUUM (can take minutes on multi-GB DBs)…"
sqlite3 "$DB" "PRAGMA busy_timeout=60000; VACUUM;"

echo "[prune] after:  $(du -h "$DB" | awk '{print $1}')  wal=$(du -h "${DB}-wal" 2>/dev/null | awk '{print $1}' || echo 0)"
echo "[prune] workspace thread counts:"
sqlite3 "$DB" "SELECT workspace_id, COUNT(*) FROM agent_threads GROUP BY workspace_id ORDER BY COUNT(*) DESC LIMIT 20;"
echo "[prune] max messages/thread:"
sqlite3 "$DB" "SELECT MAX(c) FROM (SELECT COUNT(*) AS c FROM agent_messages GROUP BY thread_id);"
echo "[prune] done"

#!/usr/bin/env bash
# One-shot prune of RemoteCode SQLite to match product retention:
#   - hard max 20 threads per workspace (oldest terminal history first;
#     never running/pending/pinned/draft/worktree)
#   - last 100 agent_messages per thread
#   - last 100 stream events / provider logs per run or thread
#
# Usage:
#   scripts/prune-agent-storage-one-shot.sh [/path/to/remotecode.sqlite]
set -euo pipefail

DB="${1:-$HOME/Library/Application Support/RemoteCode/remotecode.sqlite}"
MAX_THREADS=20
MAX_MSGS=100
MAX_EVENTS=100

if [[ ! -f "$DB" ]]; then
  echo "[prune] missing db: $DB" >&2
  exit 1
fi

echo "[prune] db=$DB"
echo "[prune] before: $(du -h "$DB" | awk '{print $1}')"

sqlite3 "$DB" <<SQL
PRAGMA busy_timeout=120000;
BEGIN IMMEDIATE;

DELETE FROM agent_messages
WHERE rowid IN (
  SELECT rowid FROM (
    SELECT rowid,
           ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY created_at DESC, rowid DESC) AS rn
    FROM agent_messages
  ) WHERE rn > ${MAX_MSGS}
);

DELETE FROM agent_provider_event_logs
WHERE id IN (
  SELECT id FROM (
    SELECT id,
           ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY id DESC) AS rn
    FROM agent_provider_event_logs
  ) WHERE rn > ${MAX_EVENTS}
);

DELETE FROM agent_stream_events
WHERE rowid IN (
  SELECT rowid FROM (
    SELECT rowid,
           ROW_NUMBER() OVER (PARTITION BY run_id ORDER BY seq DESC, rowid DESC) AS rn
    FROM agent_stream_events
  ) WHERE rn > ${MAX_EVENTS}
);

-- Hard cap: delete oldest terminal, unpinned, non-worktree, non-draft threads
-- until each workspace has at most MAX_THREADS. CASCADE removes messages/runs.
DELETE FROM agent_threads
WHERE id IN (
  SELECT id FROM (
    SELECT t.id AS id,
           ROW_NUMBER() OVER (
             PARTITION BY t.workspace_id
             ORDER BY t.updated_at ASC, t.id ASC
           ) AS rn,
           COUNT(*) OVER (PARTITION BY t.workspace_id) AS total
    FROM agent_threads t
    WHERE t.status != 'running'
      AND t.pinned = 0
      AND (t.worktree_path IS NULL OR TRIM(t.worktree_path) = '')
      AND NOT EXISTS (
        SELECT 1 FROM agent_thread_drafts d
        WHERE d.thread_id = t.id
          AND (LENGTH(TRIM(COALESCE(d.text,''))) > 0
               OR LENGTH(TRIM(COALESCE(d.attachments_json,'[]'))) > 2)
      )
      AND NOT EXISTS (
        SELECT 1 FROM agent_thread_fork_intents i
        WHERE i.state IN ('prepared','provider_created','compensating')
          AND (i.source_thread_id = t.id OR i.child_thread_id = t.id)
      )
  )
  WHERE total > ${MAX_THREADS}
    AND rn <= (total - ${MAX_THREADS})
);

COMMIT;

SELECT 'threads', COUNT(*) FROM agent_threads;
SELECT 'messages', COUNT(*) FROM agent_messages;
SELECT 'provider_logs', COUNT(*) FROM agent_provider_event_logs;
SELECT 'stream_events', COUNT(*) FROM agent_stream_events;
SELECT 'max_threads_per_ws', COALESCE(MAX(c),0) FROM (SELECT COUNT(*) c FROM agent_threads GROUP BY workspace_id);
SQL

echo "[prune] vacuum…"
sqlite3 "$DB" "PRAGMA busy_timeout=120000; VACUUM;"
echo "[prune] after: $(du -h "$DB" | awk '{print $1}')"
echo "[prune] top workspaces:"
sqlite3 "$DB" "SELECT workspace_id, COUNT(*) c FROM agent_threads GROUP BY workspace_id ORDER BY c DESC LIMIT 15;"
echo "[prune] done"

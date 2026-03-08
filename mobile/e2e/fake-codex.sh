#!/usr/bin/env bash
set -euo pipefail

thread_id="e2e-thread-${RANDOM}${RANDOM}"

printf '{"thread_id":"%s","type":"thread.started"}\n' "${thread_id}"
sleep 0.05
printf '{"type":"turn.started"}\n'
sleep 0.05
printf '{"item":{"id":"reasoning-1","type":"reasoning"},"type":"item.started"}\n'
sleep 0.05
printf '{"item":{"id":"reasoning-1","text":"Planning deterministic reply","type":"reasoning"},"type":"item.completed"}\n'
sleep 0.05
printf '{"item":{"id":"msg-1","type":"agent_message"},"type":"item.started"}\n'
sleep 0.05
printf '{"item":{"delta":"E2E assistant ","id":"msg-1","type":"agent_message"},"type":"item.delta"}\n'
sleep 0.05
printf '{"item":{"id":"msg-1","text":"E2E assistant reply","type":"agent_message"},"type":"item.completed"}\n'
sleep 0.05
printf '{"type":"turn.completed"}\n'

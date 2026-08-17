#!/usr/bin/env bash
set -euo pipefail
# Loop local "aqui" a cada 5 minutos com single-flight (não inicia outra se anterior viva)
# Não usa crontab/launchd do sistema — roda como processo detached neste workspace
REPO_ROOT="/Users/samuelfajreldines/dev/remote-code/macos-app"
SCRIPT="$REPO_ROOT/scripts/autoloop-performance-5min.sh"
LOG="/tmp/perf-loop-here.log"
echo "[$(date -u +%FT%TZ)] perf-loop-here iniciado PID $$ (intervalo 300s, single-flight via $SCRIPT)" | tee -a "$LOG"
while true; do
  echo "[$(date -u +%FT%TZ)] tick: chamando $SCRIPT" >> "$LOG"
  # single-flight está dentro do autoloop (flock/mkdir) — aqui só chama e loga
  "$SCRIPT" >> "$LOG" 2>&1 || echo "[$(date -u +%FT%TZ)] tick falhou exit $?" >> "$LOG"
  echo "[$(date -u +%FT%TZ)] tick done, dormindo 300s" >> "$LOG"
  sleep 300
done

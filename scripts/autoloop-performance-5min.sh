#!/usr/bin/env bash
# 5-minute autoloop with single-flight (não inicia outra se anterior viva)
# Uso com cron/launchd: */5 * * * * /Users/samuelfajreldines/dev/remote-code/macos-app/scripts/autoloop-performance-5min.sh
set -euo pipefail
REPO_ROOT="/Users/samuelfajreldines/dev/remote-code/macos-app"
LOCK_DIR="$REPO_ROOT/.rc-autoloops/locks"
LOCK_FILE="$LOCK_DIR/performance.lock"
mkdir -p "$LOCK_DIR"

# Single-flight portável: flock (Linux) ou mkdir atômico (macOS)
if command -v flock >/dev/null 2>&1; then
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    echo "[$(date -u +%FT%TZ)] performance autoloop skip: anterior ainda rodando (flock $LOCK_FILE)" >&2
    exit 0
  fi
else
  if ! mkdir "$LOCK_FILE.dir" 2>/dev/null; then
    echo "[$(date -u +%FT%TZ)] performance autoloop skip: anterior ainda rodando (mkdir $LOCK_FILE.dir)" >&2
    exit 0
  fi
  trap 'rmdir "$LOCK_FILE.dir" 2>/dev/null || true' EXIT
fi

# Registra PID para debug sem expor segredos
echo $$ > "$LOCK_FILE.pid" 2>/dev/null || true

# 1) garante origin/production atualizado (read-only check)
git -C "$REPO_ROOT" fetch origin production 2>&1 | head -20 || echo "fetch falhou, segue com HEAD local" >&2

# 2) calcula fingerprint estável (mesma lógica de loops/_shared.md)
# loop=performance|behavior=<scenario>|seam=<modulo> — fingerprint fixa o MR
SCENARIO="agent-app-stream-hotpath"
SEAM="Sources/CoreModel/AssistantEvents+Sources/Surfaces/AgentAppSurface"
FP=$(printf "loop=performance|behavior=%s|seam=%s" "$SCENARIO" "$SEAM" | shasum -a 256 | cut -c1-12)
BRANCH="auto/performance/$FP"
WT_BASE="/Users/samuelfajreldines/dev/remote-code/.worktrees"
WT="$WT_BASE/perf-autoloop-$FP"

# 3) procura MR aberto existente com marcador rc-autoloop:v1 para reutilizar
EXISTING_MR=$(glab mr list --repo desenvolvimento-ninja/remodecode/remotecode --search "rc-autoloop:v1 loop=performance fingerprint=$FP" --output json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['iid'] if d else '')" 2>/dev/null || echo "")

if [ -n "$EXISTING_MR" ]; then
  echo "MR existente encontrado: !$EXISTING_MR para fingerprint $FP — será atualizado, não criado novo" >&2
else
  echo "Nenhum MR aberto para fingerprint $FP — será criado na primeira entrega COMPLETE" >&2
fi

# 4) cria/atualiza worktree isolado a partir de origin/production (nunca toca worktree primário sujo)
# Reusa worktree existente se branch já tem worktree em qualquer path (evita 'already used')
EXISTING_WT=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | awk -v br="refs/heads/$BRANCH" ' $1=="worktree" {wt=$2} $1=="branch" && $2==br {print wt; exit}')
if [ -n "$EXISTING_WT" ] && [ -d "$EXISTING_WT" ]; then
  WT="$EXISTING_WT"
  echo "Worktree já existe em $WT (branch $BRANCH) — reutilizando" >&2
elif [ -d "$WT" ]; then
  echo "Worktree já existe em $WT — reutilizando" >&2
else
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$REPO_ROOT" worktree add "$WT" "$BRANCH" 2>&1 | head -20 || {
      # Se branch já está em outro worktree (ex: /tmp), reutiliza
      EXISTING_WT=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | awk -v br="refs/heads/$BRANCH" ' $1=="worktree" {wt=$2} $1=="branch" && $2==br {print wt; exit}')
      if [ -n "$EXISTING_WT" ]; then WT="$EXISTING_WT"; echo "Worktree existente detectado em $WT — reutilizando" >&2; else exit 1; fi
    }
  else
    git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WT" origin/production 2>&1 | head -20
  fi
fi

cd "$WT" || exit 1

# 5) Sempre commitar — heartbeat para provar liveness do loop (mesmo sem diff perf)
# Mantém MR !241 sempre atualizado a cada tick, sem depender de NO_CHANGE
STAMP=$(date -u +%FT%TZ)
HEARTBEAT_DIR="loops-out/perf-$FP"
mkdir -p "$HEARTBEAT_DIR"
echo "$STAMP fingerprint=$FP branch=$BRANCH host=$(hostname -s 2>/dev/null || echo macos)" > "$HEARTBEAT_DIR/heartbeat-$STAMP.txt"
# Opcional: registra também o estado do MR para debug
echo "tick $STAMP -> MR !${EXISTING_MR:-241} worktree $WT" >> "$HEARTBEAT_DIR/ticks.log" 2>/dev/null || true
git add "$HEARTBEAT_DIR" 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "chore(loop): heartbeat $STAMP fingerprint $FP [skip ci]

Loop 5m single-flight sempre committa. Prova de liveness mesmo sem fix perf.
MR !241 fingerprint $FP branch $BRANCH" 2>&1 | head -20
  git push origin HEAD 2>&1 | head -20 || echo "push falhou (rede/permissão), commit local mantido" >&2
else
  # Mesmo sem arquivo novo (ex: tick duplicado no mesmo segundo), força empty commit para cumprir 'sempre commitar'
  git commit --allow-empty -m "chore(loop): heartbeat $STAMP fingerprint $FP [skip ci]

Loop 5m single-flight — empty heartbeat (sem diff). Mantém MR vivo." 2>&1 | head -20
  git push origin HEAD 2>&1 | head -20 || echo "push falhou, empty commit local" >&2
fi
# Retenção: evita crescimento ilimitado de heartbeat files/logs (memória/disco)
# Mantém apenas 50 heartbeats mais recentes → de 288/dia ilimitado para 50 fixos (-82% após 1 dia, -98% após 30 dias)
ls -t "$HEARTBEAT_DIR"/heartbeat-*.txt 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null || true
if [ -f "$HEARTBEAT_DIR/ticks.log" ]; then tail -n 200 "$HEARTBEAT_DIR/ticks.log" > "$HEARTBEAT_DIR/ticks.log.tmp" 2>/dev/null && mv "$HEARTBEAT_DIR/ticks.log.tmp" "$HEARTBEAT_DIR/ticks.log" 2>/dev/null || true; fi
# Se houve prune, commita a limpeza para manter repo leve
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  git add -A "$HEARTBEAT_DIR" 2>/dev/null || true
  git commit -m "chore(loop): prune heartbeat retention 50 [skip ci]

Mantém disco/memória leve: -98% após 30 dias vs ilimitado." 2>&1 | head -10
  git push origin HEAD 2>&1 | head -10 || true
fi

echo "Worktree pronto em $WT branch $BRANCH fingerprint $FP (heartbeat $STAMP commitado)"

# flock libera automaticamente ao fechar fd 200

#!/usr/bin/env bash
# Endless Space Invaders animation for terminal rendering tests.
# No input required. Ctrl-C to quit.

set -u

ESC=$'\033'
ALT_ON="${ESC}[?1049h"
ALT_OFF="${ESC}[?1049l"
CUR_HIDE="${ESC}[?25l"
CUR_SHOW="${ESC}[?25h"
RESET="${ESC}[0m"
CLEAR="${ESC}[2J"
HOME="${ESC}[H"

cleanup() {
  printf '%s%s%s' "$RESET" "$CUR_SHOW" "$ALT_OFF"
  exit 0
}
trap cleanup INT TERM HUP EXIT

# Detect terminal size; fall back to 80x24.
COLS=$(tput cols 2>/dev/null || echo 80)
ROWS=$(tput lines 2>/dev/null || echo 24)
[ "$COLS" -lt 40 ] && COLS=40
[ "$ROWS" -lt 16 ] && ROWS=16

# Colors
C_RESET="${ESC}[0m"
C_DIM="${ESC}[2;37m"
C_STAR="${ESC}[1;37m"
C_ALIEN1="${ESC}[1;32m"
C_ALIEN2="${ESC}[1;35m"
C_ALIEN3="${ESC}[1;36m"
C_SHIP="${ESC}[1;33m"
C_BULLET="${ESC}[1;31m"
C_HUD="${ESC}[1;34m"
C_BOOM="${ESC}[1;31m"

# Alien sprites (two frames each, 3 cols wide).
A1_A=(">o<")
A1_B=("<o>")
A2_A=("/X\\")
A2_B=("\\X/")
A3_A=("[#]")
A3_B=("(#)")

SHIP="<A>"

# Alien grid layout
ROWS_ALIENS=3
COLS_ALIENS=$(( (COLS - 8) / 5 ))
[ "$COLS_ALIENS" -gt 11 ] && COLS_ALIENS=11
[ "$COLS_ALIENS" -lt 4 ] && COLS_ALIENS=4

ALIEN_SPACING=5
GRID_WIDTH=$(( COLS_ALIENS * ALIEN_SPACING ))
ALIEN_X=2
ALIEN_Y=3
ALIEN_DIR=1
FRAME=0

# Ship position
SHIP_Y=$(( ROWS - 2 ))
SHIP_X=$(( COLS / 2 - 1 ))
SHIP_DIR=1

# Bullets: parallel arrays of x,y,dy (dy=-1 ship, dy=+1 alien)
BULLET_X=()
BULLET_Y=()
BULLET_DY=()

# Alien alive mask: 1=alive, 0=dead, index = row*COLS_ALIENS+col
ALIVE=()
respawn_aliens() {
  ALIVE=()
  for ((i=0; i<ROWS_ALIENS*COLS_ALIENS; i++)); do ALIVE+=(1); done
}
respawn_aliens

# Pre-generate starfield
STAR_COUNT=$(( COLS * ROWS / 40 ))
STAR_X=()
STAR_Y=()
STAR_PH=()
for ((i=0; i<STAR_COUNT; i++)); do
  STAR_X+=($(( RANDOM % COLS + 1 )))
  STAR_Y+=($(( RANDOM % (ROWS - 3) + 1 )))
  STAR_PH+=($(( RANDOM % 4 )))
done

SCORE=0
WAVE=1

move_to() { printf '%s[%d;%dH' "$ESC" "$1" "$2"; }

draw_frame() {
  local out=""
  out+="$HOME$CLEAR"

  # Stars
  local sx sy ph ch
  for ((i=0; i<STAR_COUNT; i++)); do
    sx=${STAR_X[i]}
    sy=${STAR_Y[i]}
    ph=$(( (STAR_PH[i] + FRAME / 3) % 8 ))
    case $ph in
      0|4) ch="."; out+="${C_DIM}";;
      1|3|5|7) ch="+"; out+="${C_STAR}";;
      2) ch="*"; out+="${C_STAR}";;
      6) ch="."; out+="${C_DIM}";;
    esac
    out+="${ESC}[${sy};${sx}H${ch}"
  done

  # Aliens
  local row col idx ax ay sprite color
  local sf=$(( (FRAME / 4) % 2 ))
  for ((row=0; row<ROWS_ALIENS; row++)); do
    for ((col=0; col<COLS_ALIENS; col++)); do
      idx=$(( row * COLS_ALIENS + col ))
      [ "${ALIVE[idx]}" -eq 0 ] && continue
      ax=$(( ALIEN_X + col * ALIEN_SPACING ))
      ay=$(( ALIEN_Y + row * 2 ))
      case $row in
        0) color=$C_ALIEN3; [ $sf -eq 0 ] && sprite=$A3_A || sprite=$A3_B;;
        1) color=$C_ALIEN2; [ $sf -eq 0 ] && sprite=$A2_A || sprite=$A2_B;;
        *) color=$C_ALIEN1; [ $sf -eq 0 ] && sprite=$A1_A || sprite=$A1_B;;
      esac
      out+="${ESC}[${ay};${ax}H${color}${sprite}"
    done
  done

  # Ship
  out+="${ESC}[${SHIP_Y};${SHIP_X}H${C_SHIP}${SHIP}"

  # Bullets
  local bx by bd glyph
  for ((i=0; i<${#BULLET_X[@]}; i++)); do
    bx=${BULLET_X[i]}
    by=${BULLET_Y[i]}
    bd=${BULLET_DY[i]}
    if [ "$bd" -lt 0 ]; then glyph="|"; else glyph="!"; fi
    out+="${ESC}[${by};${bx}H${C_BULLET}${glyph}"
  done

  # HUD
  out+="${ESC}[1;1H${C_HUD}SCORE: ${SCORE}   WAVE: ${WAVE}   COLS:${COLS} ROWS:${ROWS}   ^C quit"
  out+="${C_RESET}"
  printf '%s' "$out"
}

step_aliens() {
  local leftmost=999 rightmost=-1 lowest=0
  local row col idx ax ay
  local any_alive=0
  for ((row=0; row<ROWS_ALIENS; row++)); do
    for ((col=0; col<COLS_ALIENS; col++)); do
      idx=$(( row * COLS_ALIENS + col ))
      [ "${ALIVE[idx]}" -eq 0 ] && continue
      any_alive=1
      ax=$(( ALIEN_X + col * ALIEN_SPACING ))
      ay=$(( ALIEN_Y + row * 2 ))
      [ "$ax" -lt "$leftmost" ] && leftmost=$ax
      [ "$ax" -gt "$rightmost" ] && rightmost=$ax
      [ "$ay" -gt "$lowest" ] && lowest=$ay
    done
  done

  if [ "$any_alive" -eq 0 ]; then
    WAVE=$(( WAVE + 1 ))
    ALIEN_X=2
    ALIEN_Y=3
    ALIEN_DIR=1
    respawn_aliens
    return
  fi

  if [ $(( FRAME % 3 )) -eq 0 ]; then
    if [ "$ALIEN_DIR" -gt 0 ] && [ $(( rightmost + 3 )) -ge "$COLS" ]; then
      ALIEN_DIR=-1
      ALIEN_Y=$(( ALIEN_Y + 1 ))
    elif [ "$ALIEN_DIR" -lt 0 ] && [ "$leftmost" -le 2 ]; then
      ALIEN_DIR=1
      ALIEN_Y=$(( ALIEN_Y + 1 ))
    else
      ALIEN_X=$(( ALIEN_X + ALIEN_DIR ))
    fi
  fi

  # Wrap if aliens reach ship
  if [ "$lowest" -ge $(( SHIP_Y - 1 )) ]; then
    ALIEN_Y=3
  fi
}

step_ship() {
  if [ $(( FRAME % 2 )) -eq 0 ]; then
    SHIP_X=$(( SHIP_X + SHIP_DIR ))
    if [ "$SHIP_X" -le 1 ]; then SHIP_DIR=1; fi
    if [ $(( SHIP_X + 3 )) -ge "$COLS" ]; then SHIP_DIR=-1; fi
  fi
}

fire_ship() {
  if [ $(( FRAME % 8 )) -eq 0 ]; then
    BULLET_X+=($(( SHIP_X + 1 )))
    BULLET_Y+=($(( SHIP_Y - 1 )))
    BULLET_DY+=(-1)
  fi
}

fire_aliens() {
  if [ $(( FRAME % 17 )) -eq 0 ]; then
    local tries=0
    while [ "$tries" -lt 5 ]; do
      local col=$(( RANDOM % COLS_ALIENS ))
      local row
      for ((row=ROWS_ALIENS-1; row>=0; row--)); do
        local idx=$(( row * COLS_ALIENS + col ))
        if [ "${ALIVE[idx]}" -eq 1 ]; then
          local ax=$(( ALIEN_X + col * ALIEN_SPACING + 1 ))
          local ay=$(( ALIEN_Y + row * 2 + 1 ))
          BULLET_X+=($ax)
          BULLET_Y+=($ay)
          BULLET_DY+=(1)
          return
        fi
      done
      tries=$(( tries + 1 ))
    done
  fi
}

step_bullets() {
  local nx=() ny=() nd=()
  local bx by bd
  for ((i=0; i<${#BULLET_X[@]}; i++)); do
    bx=${BULLET_X[i]}
    by=${BULLET_Y[i]}
    bd=${BULLET_DY[i]}
    by=$(( by + bd ))
    if [ "$by" -lt 2 ] || [ "$by" -ge "$ROWS" ]; then
      continue
    fi
    # Ship bullet hits alien?
    if [ "$bd" -lt 0 ]; then
      local hit=0
      local row col idx ax ay
      for ((row=0; row<ROWS_ALIENS; row++)); do
        ay=$(( ALIEN_Y + row * 2 ))
        [ "$by" -ne "$ay" ] && continue
        for ((col=0; col<COLS_ALIENS; col++)); do
          idx=$(( row * COLS_ALIENS + col ))
          [ "${ALIVE[idx]}" -eq 0 ] && continue
          ax=$(( ALIEN_X + col * ALIEN_SPACING ))
          if [ "$bx" -ge "$ax" ] && [ "$bx" -le $(( ax + 2 )) ]; then
            ALIVE[idx]=0
            SCORE=$(( SCORE + 10 * (ROWS_ALIENS - row) ))
            hit=1
            break
          fi
        done
        [ "$hit" -eq 1 ] && break
      done
      [ "$hit" -eq 1 ] && continue
    fi
    nx+=($bx); ny+=($by); nd+=($bd)
  done
  BULLET_X=("${nx[@]:-}")
  BULLET_Y=("${ny[@]:-}")
  BULLET_DY=("${nd[@]:-}")
  # Strip stray empty placeholders introduced by :- when empty
  if [ "${#BULLET_X[@]}" -eq 1 ] && [ -z "${BULLET_X[0]}" ]; then
    BULLET_X=(); BULLET_Y=(); BULLET_DY=()
  fi
}

# Setup terminal
printf '%s%s%s' "$ALT_ON" "$CUR_HIDE" "$CLEAR"

while true; do
  step_aliens
  step_ship
  fire_ship
  fire_aliens
  step_bullets
  draw_frame
  FRAME=$(( FRAME + 1 ))
  sleep 0.06
done

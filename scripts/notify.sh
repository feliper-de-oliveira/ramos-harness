#!/usr/bin/env bash
#
# notify.sh — camada de notificacoes do harness.
#
# Quem emite (o ralph.sh) so diz QUE algo aconteceu. Este script decide se o
# evento notifica, monta a mensagem lendo o estado do run — o mesmo run.tsv que
# o painel le, sem estado paralelo — e entrega a cada provider configurado
# (notify-<provider>.sh, ao lado deste arquivo). Quem emite nunca conhece a API
# do Telegram; um provider novo e um arquivo novo, sem tocar no ralph.
#
# Uso:
#   notify.sh <evento> [fase] [detalhe]   sempre sai 0: notificacao nunca derruba o run
#   notify.sh test                        envia uma mensagem de teste; sai 1 se falhar
#
# Eventos:
#   project.started  project.completed  project.failed
#   phase.started    phase.completed    phase.failed
#   agent.failed     needs.input
#
# Configuracao (KEY=VALUE; o arquivo e LIDO, nunca executado com `source`):
#   ~/.config/bc-harness/notifications.env   global — o unico lugar de credenciais
#   .bc-harness/notifications.env            por projeto — so chaves nao sensiveis
#   variaveis de ambiente                    vencem os dois arquivos
#
#   NOTIFICATIONS_ENABLED   true (default) | false
#   NOTIFICATION_PROVIDER   telegram (default). Lista: telegram,whatsapp
#   NOTIFY_EVENTS           eventos que notificam, por virgula, ou "all"
#                           (default: todos menos phase.started)
#   NOTIFY_TIMEOUT          segundos por envio (default: 10)
#   TELEGRAM_BOT_TOKEN      credenciais do provider telegram
#   TELEGRAM_CHAT_ID
#
# Nada configurado (sem arquivo global e sem credencial no ambiente): no-op
# silencioso — o harness funciona igual sem notificacoes.
#
# Ambiente extra: RALPH_STATE_FILE (default .phases/state/run.tsv),
# BC_HARNESS_NOTIFY_CONFIG (caminho do arquivo global).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_CONFIG="${BC_HARNESS_NOTIFY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/bc-harness/notifications.env}"
PROJECT_CONFIG=".bc-harness/notifications.env"
STATE_FILE="${RALPH_STATE_FILE:-.phases/state/run.tsv}"

SECRET_KEYS="TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID"
PUBLIC_KEYS="NOTIFICATIONS_ENABLED NOTIFICATION_PROVIDER NOTIFY_EVENTS NOTIFY_TIMEOUT"
DEFAULT_EVENTS="project.started,phase.completed,phase.failed,agent.failed,needs.input,project.completed,project.failed"
FAIL_SUFFIX=" - continuing execution"

say() { echo "[notification] $*"; }

# ---------------------------------------------------------------------------
# Configuracao
# ---------------------------------------------------------------------------

declare -A CFG=()

# load_config <arquivo> <chaves aceitas>
load_config() {
  local file="$1" allowed=" $2 " key val
  [ -f "$file" ] || return 0
  while IFS='=' read -r key val || [ -n "$key" ]; do
    key="${key#export }"
    key="${key//[[:space:]]/}"
    [[ -z "$key" || "$key" == \#* ]] && continue
    if [[ "$allowed" != *" $key "* ]]; then
      # Credencial em arquivo de projeto acaba commitada: recusa e avisa.
      [[ " $SECRET_KEYS " == *" $key "* ]] && say "$key ignorada em $file — credenciais so em $GLOBAL_CONFIG"
      continue
    fi
    val="${val%$'\r'}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ ${#val} -ge 2 && ( "$val" == \"*\" || "$val" == \'*\' ) ]]; then val="${val:1:${#val}-2}"; fi
    CFG[$key]="$val"
  done < "$file"
}

apply_config() {
  local key
  for key in $SECRET_KEYS $PUBLIC_KEYS; do
    [ -n "${!key+x}" ] && continue
    export "$key=${CFG[$key]:-}"
  done
  : "${NOTIFICATIONS_ENABLED:=true}" "${NOTIFICATION_PROVIDER:=telegram}"
  : "${NOTIFY_EVENTS:=$DEFAULT_EVENTS}" "${NOTIFY_TIMEOUT:=10}"
  export NOTIFICATIONS_ENABLED NOTIFICATION_PROVIDER NOTIFY_EVENTS NOTIFY_TIMEOUT

  if [ -f "$GLOBAL_CONFIG" ]; then
    local perm
    perm=$(stat -c %a "$GLOBAL_CONFIG" 2>/dev/null || stat -f %Lp "$GLOBAL_CONFIG" 2>/dev/null || echo "?")
    case "$perm" in
      600|400) ;;
      *) say "AVISO: $GLOBAL_CONFIG tem permissao $perm (guarda credenciais). Rode: chmod 600 $GLOBAL_CONFIG" ;;
    esac
  fi
}

configured() {
  [ -f "$GLOBAL_CONFIG" ] && return 0
  local key
  for key in $SECRET_KEYS; do [ -n "${!key:-}" ] && return 0; done
  return 1
}

event_enabled() {
  [ "$NOTIFY_EVENTS" = "all" ] && return 0
  [[ ",${NOTIFY_EVENTS// /}," == *",$1,"* ]]
}

# ---------------------------------------------------------------------------
# Estado do run (.phases/state/run.tsv) — leitura pura
# ---------------------------------------------------------------------------

declare -A META=() PH_TITLE=() PH_STATUS=() PH_ATTEMPT=()
PHASES=()

load_state() {
  [ -f "$STATE_FILE" ] || return 0
  local kind a b c d e
  while IFS=$'\t' read -r kind a b c d e; do
    case "$kind" in
      META)  META[$a]="$b" ;;
      PHASE) PHASES+=("$a"); PH_STATUS[$a]="$b"; PH_ATTEMPT[$a]="$c"; PH_TITLE[$a]="$e" ;;
    esac
  done < "$STATE_FILE"
}

project_name() { printf '%s' "${META[project]:-$(basename "$PWD")}"; }

agent_name() {
  case "${META[engine]:-}" in
    claude) printf 'Claude' ;;
    codex)  printf 'Codex' ;;
    *)      printf '%s' "${META[engine]:-agente}" ;;
  esac
}

dur() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  if [ "$s" -ge 3600 ]; then printf '%dh %02dmin' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then printf '%d min' $((s / 60))
  else printf '%ds' "$s"; fi
}

# 04/09
phase_label() {
  local n="$1" total="${META[phase_total]:-0}"
  [[ "$n" =~ ^[0-9]+$ ]] || { printf '%s' "$n"; return; }
  printf '%02d/%02d' "$((10#$n))" "$((10#$total))"
}

count_done() {
  local n c=0
  for n in "${PHASES[@]}"; do [ "${PH_STATUS[$n]}" = "done" ] && c=$((c + 1)); done
  echo "$c"
}

next_phase() {
  local cur="$1" n
  for n in "${PHASES[@]}"; do
    [ "${PH_STATUS[$n]}" = "pending" ] && [ "$n" -gt "$cur" ] 2>/dev/null \
      && { printf '%s — %s' "$(phase_label "$n")" "${PH_TITLE[$n]}"; return; }
  done
}

# Telegram nao e lugar de stack trace: o detalhe vai cortado, o log fica local.
clip() {
  local t="$1"
  [ "${#t}" -gt 600 ] && t="${t:0:600}…"
  printf '%s' "$t"
}

# ---------------------------------------------------------------------------
# Mensagens
# ---------------------------------------------------------------------------

# build_message <evento> [fase] [detalhe] -> mensagem em texto puro
build_message() {
  local event="$1" num="${2:-}" detail
  detail=$(clip "${3:-}")
  local proj="📦 Projeto: $(project_name)"
  local where=""
  [ -n "$num" ] && where="📍 Fase: $(phase_label "$num")"$'\n\n'"${PH_TITLE[$num]:-}"
  local total="${META[phase_total]:-0}"

  case "$event" in
    project.started)
      local pending=0 n
      for n in "${PHASES[@]}"; do [ "${PH_STATUS[$n]}" = "pending" ] && pending=$((pending + 1)); done
      local fases="$total"
      [ "$pending" -ne "$total" ] && fases="$total ($pending pendentes)"
      printf '🚀 RALPH INICIADO\n\n%s\n\nFases: %s\nAgente: %s\n\nExecução iniciada.' \
        "$proj" "$fases" "$(agent_name)"
      ;;
    phase.started)
      printf '▶️ FASE INICIADA\n\n%s\n%s\n\nAgente: %s' "$proj" "$where" "$(agent_name)"
      ;;
    phase.completed)
      local next
      next=$(next_phase "$num")
      printf '✅ FASE CONCLUÍDA\n\n%s\n%s\n\n⏱ Duração: %s' "$proj" "$where" "$(dur "${META[tdur_$num]:-0}")"
      [ -n "$next" ] && printf '\n\n➡️ Próxima:\n%s' "$next"
      ;;
    phase.failed)
      local status="Execução interrompida."
      [ "${META[keep_going]:-false}" = "true" ] && status="Seguindo para a próxima fase (--keep-going)."
      printf '❌ ERRO NO RALPH\n\n%s\n%s\n\nErro:\n%s\n\nStatus:\n%s' \
        "$proj" "$where" "${detail:-${META[last_error]:-sem detalhe}}" "$status"
      ;;
    agent.failed)
      local status="Ralph vai tentar um ciclo de correção."
      [ "${PH_ATTEMPT[$num]:-0}" -ge "${META[cycle_max]:-0}" ] 2>/dev/null \
        && status="Era o último ciclo: a fase será reprovada."
      printf '⚠️ AGENTE FALHOU\n\n%s\n%s\n\nAgente: %s — ciclo %s/%s\n\nErro:\n%s\n\nStatus:\n%s' \
        "$proj" "$where" "$(agent_name)" "${PH_ATTEMPT[$num]:-?}" "${META[cycle_max]:-?}" \
        "${detail:-sem detalhe}" "$status"
      ;;
    needs.input)
      printf '⚠️ RALPH PRECISA DE VOCÊ\n\n%s\n%s\n\n%s interrompeu a execução.\n\nMotivo:\n%s\n\nStatus:\n⏸ Aguardando intervenção' \
        "$proj" "$where" "$(agent_name)" "${detail:-não informado}"
      ;;
    project.completed)
      printf '🎉 PROJETO CONCLUÍDO\n\n%s\n\n✅ %s/%s fases concluídas\n\n⏱ Tempo total: %s\n\nRalph finalizou a execução.' \
        "$proj" "$(count_done)" "$total" "$(dur $(( ${META[ended]:-0} - ${META[started]:-0} )))"
      ;;
    project.failed)
      local ended="${META[ended]:-}"
      [ -n "$ended" ] || ended=$(date +%s)
      printf '❌ RALPH PAROU COM FALHA\n\n%s\n\n✅ %s/%s fases concluídas\n\n⏱ Tempo: %s\n\nErro:\n%s\n\nLogs: .phases/logs/' \
        "$proj" "$(count_done)" "$total" "$(dur $(( ended - ${META[started]:-ended} )))" \
        "${detail:-${META[last_error]:-sem detalhe}}"
      ;;
    *)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Entrega
# ---------------------------------------------------------------------------

# deliver <evento> <mensagem> -> 0 se ao menos um provider entregou
deliver() {
  local event="$1" msg="$2" p script out rc delivered=1
  for p in ${NOTIFICATION_PROVIDER//,/ }; do
    script="$HERE/notify-$p.sh"
    if [[ ! "$p" =~ ^[a-z0-9_-]+$ ]] || [ ! -f "$script" ]; then
      say "provider desconhecido: '$p' (esperado $HERE/notify-<provider>.sh)"
      continue
    fi
    out=$(printf '%s' "$msg" | bash "$script" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      say "$p $event sent"
      delivered=0
    else
      say "$p $event failed: $(tail -n 1 <<< "${out:-codigo $rc}")$FAIL_SUFFIX"
    fi
  done
  return "$delivered"
}

run_test() {
  FAIL_SUFFIX=""
  if ! configured; then
    say "nada configurado: crie $GLOBAL_CONFIG com as credenciais do provider."
    say "Passo a passo no README, secao 'Notificacoes'."
    return 1
  fi
  [ "$NOTIFICATIONS_ENABLED" = "true" ] \
    || say "aviso: NOTIFICATIONS_ENABLED=$NOTIFICATIONS_ENABLED — o ralph nao vai notificar; o teste envia mesmo assim."
  local msg
  msg=$(printf '🧪 BC HARNESS\n\n%s configurado corretamente.\n\nProjeto: %s\nStatus: conexão funcionando.' \
    "${NOTIFICATION_PROVIDER^}" "$(basename "$PWD")")
  deliver test "$msg"
}

main() {
  local event="${1:-}"
  case "$event" in
    ""|-h|--help) sed -n '2,38p' "$0"; return 0 ;;
  esac

  load_config "$GLOBAL_CONFIG" "$SECRET_KEYS $PUBLIC_KEYS"
  load_config "$PROJECT_CONFIG" "$PUBLIC_KEYS"
  apply_config

  if [ "$event" = "test" ]; then
    run_test
    return
  fi

  [ "$NOTIFICATIONS_ENABLED" = "true" ] || return 0
  configured || return 0
  event_enabled "$event" || return 0

  load_state
  local msg
  if ! msg=$(build_message "$@"); then
    say "evento desconhecido: $event"
    return 0
  fi
  deliver "$event" "$msg" || true
  return 0
}

main "$@"

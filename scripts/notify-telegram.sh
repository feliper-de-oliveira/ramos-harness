#!/usr/bin/env bash
#
# notify-telegram.sh — provider Telegram do notify.sh (Bot API, sendMessage).
#
# Mensagem pelo stdin; credenciais pelo ambiente (TELEGRAM_BOT_TOKEN,
# TELEGRAM_CHAT_ID), que o notify.sh carrega de ~/.config/ramos-harness/.
# Exit 0 = entregue. Em falha imprime UMA linha curta — nunca o token nem a URL.
#
# O token chega ao curl pelo stdin (--config -), nao por argumento: nao aparece
# em `ps` nem em mensagem de erro do curl. Texto puro, sem parse_mode: qualquer
# caractere passa sem escaping.
#
# Ambiente extra: NOTIFY_TIMEOUT (segundos, default 10), TELEGRAM_API_BASE
# (default https://api.telegram.org; a suite aponta para um servidor local).

set -uo pipefail

token="${TELEGRAM_BOT_TOKEN:-}"
chat="${TELEGRAM_CHAT_ID:-}"
api="${TELEGRAM_API_BASE:-https://api.telegram.org}"
timeout="${NOTIFY_TIMEOUT:-10}"

[ -n "$token" ] || { echo "TELEGRAM_BOT_TOKEN ausente"; exit 1; }
[ -n "$chat" ]  || { echo "TELEGRAM_CHAT_ID ausente"; exit 1; }
# Formato do BotFather (123456789:AA...). Tambem impede que o valor quebre a
# linha de config entregue ao curl.
[[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { echo "TELEGRAM_BOT_TOKEN com formato invalido (esperado <numero>:<chave>)"; exit 1; }
[[ "$chat" =~ ^-?[0-9]+$|^@[A-Za-z0-9_]+$ ]] || { echo "TELEGRAM_CHAT_ID com formato invalido (numero, ou @canal)"; exit 1; }
[[ "$timeout" =~ ^[0-9]+$ ]] || timeout=10
command -v curl > /dev/null || { echo "curl nao encontrado"; exit 1; }

text=$(cat)
# Limite da API: 4096 caracteres por mensagem.
[ "${#text}" -gt 4000 ] && text="${text:0:4000}…"

resp=$(printf 'url = "%s/bot%s/sendMessage"\n' "$api" "$token" \
  | curl -s --config - \
      --connect-timeout "$(( timeout < 5 ? timeout : 5 ))" --max-time "$timeout" \
      --data-urlencode "chat_id=$chat" \
      --data-urlencode "text=$text" \
      -w '\n%{http_code}')
rc=$?

case "$rc" in
  0)  ;;
  6)  echo "sem conexao (DNS nao resolveu o host da API)"; exit 1 ;;
  7)  echo "sem conexao com a API do Telegram"; exit 1 ;;
  28) echo "timeout apos ${timeout}s falando com a API do Telegram"; exit 1 ;;
  *)  echo "curl falhou (codigo $rc)"; exit 1 ;;
esac

code="${resp##*$'\n'}"
body="${resp%$'\n'*}"
desc=$(sed -n 's/.*"description"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$body")

case "$code" in
  200)     [[ "$body" =~ \"ok\"[[:space:]]*:[[:space:]]*true ]] && exit 0
           echo "resposta inesperada da API" ;;
  401|404) echo "token invalido (HTTP $code)" ;;
  400|403) echo "Telegram recusou (HTTP $code): ${desc:-sem descricao} — confira TELEGRAM_CHAT_ID e se voce mandou /start ao bot" ;;
  429)     echo "rate limit do Telegram (HTTP 429)" ;;
  5*)      echo "Telegram indisponivel (HTTP $code)" ;;
  *)       echo "HTTP $code${desc:+: $desc}" ;;
esac
exit 1

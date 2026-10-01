#!/usr/bin/env bash
#
# test-notify.sh — suite do notify.sh + notify-telegram.sh.
#
# Nenhuma chamada a api.telegram.org: um servidor HTTP local (python3) faz o
# papel da Bot API. O cenario sai do proprio token: 1:ok, 1:bad (401),
# 1:down (502), 1:chat (400), 1:slow (dorme 5s).
#
# Uso: scripts/test-notify.sh   (exit 0 = tudo verde)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY="$ROOT/scripts/notify.sh"
TMP=$(mktemp -d)
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()  { PASS=$((PASS + 1)); echo -e "  ${GREEN}ok${NC}   $1"; }
bad() { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC} $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (esperado '$1', veio '$2')"; fi; }
assert_has() { if grep -qF -- "$2" <<< "$1"; then ok "$3"; else bad "$3 (nao achou '$2' em: $1)"; fi; }
assert_lacks() { if grep -qF -- "$2" <<< "$1"; then bad "$3 (achou '$2')"; else ok "$3"; fi; }
header() { echo -e "\n${YELLOW}== $1${NC}"; }

# --- Bot API falsa -----------------------------------------------------------
cat > "$TMP/fake_telegram.py" <<'PY'
import http.server, json, sys, time, urllib.parse
port_file, log_file = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        token = self.path.split("/")[1][3:]
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        form = urllib.parse.parse_qs(body)
        with open(log_file, "a") as f:
            f.write(json.dumps({"chat_id": form.get("chat_id", [""])[0],
                                "text": form.get("text", [""])[0]}) + "\n")
        scen = token.split(":")[1]
        if scen == "slow":
            time.sleep(5)
        code, resp = {
            "bad": (401, {"ok": False, "error_code": 401, "description": "Unauthorized"}),
            "down": (502, {"ok": False}),
            "chat": (400, {"ok": False, "error_code": 400, "description": "Bad Request: chat not found"}),
        }.get(scen, (200, {"ok": True, "result": {"message_id": 1}}))
        out = json.dumps(resp).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a):
        pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY

python3 "$TMP/fake_telegram.py" "$TMP/port" "$TMP/requests.jsonl" &
SRV_PID=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
API="http://127.0.0.1:$(cat "$TMP/port")"

# Projeto falso com run.tsv, como o ralph deixa no meio de um run.
PROJ="$TMP/radix"
mkdir -p "$PROJ/.phases/state"
now=$(date +%s)
{
  printf 'META\tproject\tRadix\nMETA\tengine\tclaude\nMETA\tphase_total\t9\n'
  printf 'META\tstarted\t%s\nMETA\tended\t%s\nMETA\tcycle_max\t3\nMETA\tkeep_going\tfalse\n' "$((now - 13320))" "$now"
  printf 'META\ttdur_4\t2040\nMETA\tlast_error\tgate 2 vermelho\n'
  printf 'PHASE\t4\tdone\t1\tpass pass pass pass\tIntegração YouVersion\n'
  printf 'PHASE\t5\tpending\t0\tpending pending pending pending\tPersonalização das jornadas\n'
} > "$PROJ/.phases/state/run.tsv"

# run_notify <arquivo de config ou ""> <args...> — ambiente limpo; ecoa saida e
# grava o exit code em $TMP/rc.
run_notify() {
  local cfg="$1"; shift
  (
    cd "$PROJ" || exit 1
    env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID -u NOTIFICATIONS_ENABLED \
        -u NOTIFICATION_PROVIDER -u NOTIFY_EVENTS -u NOTIFY_TIMEOUT \
      RAMOS_HARNESS_NOTIFY_CONFIG="${cfg:-$TMP/none.env}" \
      TELEGRAM_API_BASE="${CASE_API:-$API}" \
      ${CASE_ENV:-} bash "$NOTIFY" "$@" 2>&1
  )
  echo $? > "$TMP/rc"
}
last_text() { tail -n 1 "$TMP/requests.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])'; }
requests() { [ -f "$TMP/requests.jsonl" ] && wc -l < "$TMP/requests.jsonl" || echo 0; }

cfg() { # cfg <nome> <conteudo> -> caminho, modo 600
  printf '%s\n' "$2" > "$TMP/$1.env"; chmod 600 "$TMP/$1.env"; echo "$TMP/$1.env"
}

header "1. configurado -> teste entregue"
c=$(cfg ok 'TELEGRAM_BOT_TOKEN="1:ok"
TELEGRAM_CHAT_ID="42"')
out=$(run_notify "$c" test)
assert_eq 0 "$(cat "$TMP/rc")" "exit 0"
assert_has "$out" "[notification] telegram test sent" "log de envio"
assert_has "$(last_text)" "Telegram configurado corretamente." "mensagem de teste"
assert_has "$(last_text)" "Projeto: radix" "projeto atual"

header "2. token ausente"
c=$(cfg notoken 'TELEGRAM_CHAT_ID=42')
out=$(run_notify "$c" test)
assert_eq 1 "$(cat "$TMP/rc")" "teste sai 1"
assert_has "$out" "TELEGRAM_BOT_TOKEN ausente" "diz o que falta"
out=$(run_notify "$c" phase.completed 4)
assert_eq 0 "$(cat "$TMP/rc")" "evento nunca sai != 0"

header "3. chat id ausente"
c=$(cfg nochat 'TELEGRAM_BOT_TOKEN=1:ok')
out=$(run_notify "$c" test)
assert_has "$out" "TELEGRAM_CHAT_ID ausente" "diz o que falta"

header "4. token invalido"
c=$(cfg bad 'TELEGRAM_BOT_TOKEN=1:bad
TELEGRAM_CHAT_ID=42')
out=$(run_notify "$c" test)
assert_eq 1 "$(cat "$TMP/rc")" "teste sai 1"
assert_has "$out" "token invalido (HTTP 401)" "401 mapeado"
assert_lacks "$out" "1:bad" "token nunca na saida"
c=$(cfg malformed 'TELEGRAM_BOT_TOKEN=abc"; rm -rf /
TELEGRAM_CHAT_ID=42')
out=$(run_notify "$c" test)
assert_has "$out" "formato invalido" "token malformado barrado antes do curl"

header "5. sem conexao"
c=$(cfg ok2 'TELEGRAM_BOT_TOKEN=1:ok
TELEGRAM_CHAT_ID=42')
out=$(CASE_API=http://127.0.0.1:9 run_notify "$c" test)
assert_has "$out" "sem conexao" "porta fechada"
out=$(CASE_API=http://nao-existe.invalid run_notify "$c" project.started)
assert_eq 0 "$(cat "$TMP/rc")" "evento sai 0 sem rede"
assert_has "$out" "failed: sem conexao" "DNS mapeado"
assert_has "$out" "continuing execution" "segue a execucao"

header "6. timeout"
c=$(cfg slow 'TELEGRAM_BOT_TOKEN=1:slow
TELEGRAM_CHAT_ID=42
NOTIFY_TIMEOUT=1')
t0=$(date +%s)
out=$(run_notify "$c" project.started)
assert_has "$out" "timeout apos 1s" "timeout mapeado"
[ $(( $(date +%s) - t0 )) -le 3 ] && ok "nao segura o run" || bad "nao segura o run"

header "7. Telegram indisponivel / chat errado"
c=$(cfg down 'TELEGRAM_BOT_TOKEN=1:down
TELEGRAM_CHAT_ID=42')
out=$(run_notify "$c" project.started)
assert_has "$out" "Telegram indisponivel (HTTP 502)" "5xx mapeado"
c=$(cfg chat 'TELEGRAM_BOT_TOKEN=1:chat
TELEGRAM_CHAT_ID=42')
out=$(run_notify "$c" project.started)
assert_has "$out" "chat not found" "descricao da API repassada"

header "8. caracteres especiais chegam intactos"
special=$'aspas " \' crase ` & = % + ? # <b>*_[x](y)_* \\ $HOME $(id) emoji 🚀 acento ção\nlinha 2'
out=$(run_notify "$c" needs.input 4 "$special")
c=$(cfg ok3 'TELEGRAM_BOT_TOKEN=1:ok
TELEGRAM_CHAT_ID=42')
out=$(run_notify "$c" needs.input 4 "$special")
assert_has "$out" "telegram needs.input sent" "enviado"
text=$(last_text)
[[ "$text" == *"$special"* ]] && ok "texto identico do outro lado" || bad "texto identico do outro lado"

header "9. mensagens montadas do run.tsv"
out=$(run_notify "$c" phase.completed 4)
text=$(last_text)
assert_has "$text" "✅ FASE CONCLUÍDA" "titulo"
assert_has "$text" "📦 Projeto: Radix" "projeto do run.tsv"
assert_has "$text" "📍 Fase: 04/09" "fase NN/TT"
assert_has "$text" "Integração YouVersion" "titulo da fase"
assert_has "$text" "⏱ Duração: 34 min" "duracao de tdur_N"
assert_has "$text" "05/09 — Personalização das jornadas" "proxima fase"
out=$(run_notify "$c" project.completed)
assert_has "$(last_text)" "⏱ Tempo total: 3h 42min" "tempo total"
assert_has "$(last_text)" "✅ 1/9 fases concluídas" "contagem de fases"
out=$(run_notify "$c" phase.failed 4 "Reprovada apos 3 ciclos")
assert_has "$(last_text)" "❌ ERRO NO RALPH" "falha"
assert_has "$(last_text)" "Execução interrompida." "status de parada"
long=$(printf 'x%.0s' $(seq 2000))
out=$(run_notify "$c" project.failed "" "$long")
[ "$(last_text | wc -c)" -lt 900 ] && ok "detalhe gigante cortado" || bad "detalhe gigante cortado"

header "10. filtros e configuracao"
n=$(requests)
out=$(run_notify "$c" phase.started 4)
assert_eq "$n" "$(requests)" "phase.started fora do default"
out=$(run_notify "$c" agent.started 4)
assert_eq "$n" "$(requests)" "evento fora da lista nao envia"
out=$(CASE_ENV="NOTIFY_EVENTS=all" run_notify "$c" phase.started 4)
assert_eq "$((n + 1))" "$(requests)" "NOTIFY_EVENTS=all liga phase.started"
n=$(requests)
out=$(CASE_ENV="NOTIFICATIONS_ENABLED=false" run_notify "$c" project.started)
assert_eq "$n" "$(requests)" "NOTIFICATIONS_ENABLED=false desliga"
out=$(run_notify "" project.started)
assert_eq "" "$out" "nada configurado: silencio total"
assert_eq "$n" "$(requests)" "nada configurado: nada enviado"
out=$(run_notify "" test)
assert_eq 1 "$(cat "$TMP/rc")" "teste sem config sai 1"
assert_has "$out" "nada configurado" "teste explica"

mkdir -p "$PROJ/.ramos-harness"
printf 'NOTIFICATIONS_ENABLED=false\nTELEGRAM_BOT_TOKEN=9:vazado\n' > "$PROJ/.ramos-harness/notifications.env"
out=$(run_notify "$c" project.started)
assert_eq "$n" "$(requests)" "projeto desliga via .ramos-harness/notifications.env"
assert_has "$out" "TELEGRAM_BOT_TOKEN ignorada" "credencial no projeto recusada"
rm -rf "$PROJ/.ramos-harness"

chmod 644 "$c"
out=$(run_notify "$c" project.started)
assert_has "$out" "chmod 600" "avisa permissao aberta"
chmod 600 "$c"

printf 'TELEGRAM_BOT_TOKEN=1:ok\nTELEGRAM_CHAT_ID=42\nNOTIFICATION_PROVIDER=telegram,whatsapp\n' > "$TMP/multi.env"; chmod 600 "$TMP/multi.env"
out=$(run_notify "$TMP/multi.env" project.started)
assert_has "$out" "telegram project.started sent" "lista de providers: telegram entrega"
assert_has "$out" "provider desconhecido: 'whatsapp'" "provider inexistente avisa sem quebrar"

echo "TELEGRAM_BOT_TOKEN=\$(touch $TMP/pwned)" > "$TMP/evil.env"; chmod 600 "$TMP/evil.env"
out=$(run_notify "$TMP/evil.env" test)
[ ! -e "$TMP/pwned" ] && ok "config lida, nunca executada" || bad "config lida, nunca executada"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}TODOS VERDES: $PASS asserts${NC}"
else
  echo -e "${RED}FALHAS: $FAIL${NC} / verdes: $PASS"
fi
exit $((FAIL > 0 ? 1 : 0))

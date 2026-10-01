#!/usr/bin/env python3
"""
ralph-board.py — quadro web do ralph.sh.

Leitor puro de .phases/state/ (run.tsv + live.tsv), como o ralph-watch.sh:
nao executa nada, nao escreve no estado. Serve em 127.0.0.1 duas rotas:
  /            ralph-board.html (ao lado deste script)
  /state.json  estado mesclado, Cache-Control: no-store

Uso:
  python3 ralph-board.py [--port N] [--once] [caminho-do-repo]

  --once   imprime o JSON uma vez e sai (teste, inspecao)
  --port   porta (default: 3847)

Nunca liga em 0.0.0.0: o JSON carrega caminhos e titulos escritos por um agente.
"""

import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PROSE_SKIP = re.compile(r"^\s*(#|[-*+]\s|\d+\.\s|>|\||```|<)")
BACKTICK = re.compile(r"`([^`\s]+)`")
PATHLIKE = re.compile(r"^[\w.-]+(/[\w.-]+)*\.[A-Za-z0-9]+$|^[\w.-]+/[\w./-]+$")


def fmt_dur(sec):
    sec = max(0, int(sec))
    h, m, s = sec // 3600, sec % 3600 // 60, sec % 60
    if h:
        return f"{h}h {m:02d}m"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def phase_doc(phases_dir, file):
    """Primeira prosa da fase (~280 chars) e ate seis caminhos entre crases."""
    try:
        with open(os.path.join(phases_dir, file), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return "", []

    para = []
    for line in lines[1:]:  # linha 1 e o heading "## Phase N:"
        if not line.strip() or PROSE_SKIP.match(line):
            if para:
                break
            continue
        para.append(line.strip())
    desc = " ".join(para).replace("**", "").replace("`", "")
    if len(desc) > 280:
        desc = desc[:279].rsplit(" ", 1)[0] + "…"

    files = []
    for m in BACKTICK.finditer("\n".join(lines)):
        p = m.group(1)
        if PATHLIKE.match(p) and p not in files:
            files.append(p)
            if len(files) == 6:
                break
    return desc, files


def read_state(repo):
    phases_dir = os.path.join(repo, ".phases")
    state_dir = os.path.join(phases_dir, "state")
    try:
        with open(os.path.join(state_dir, "run.tsv"), encoding="utf-8") as f:
            run = f.read().splitlines()
    except OSError:
        return {"ok": True, "idle": True, "repo": repo}

    meta, phases, by_num = {}, [], {}
    for line in run:
        c = line.split("\t")
        if c[0] == "META" and len(c) >= 3:
            meta[c[1]] = c[2]
        elif c[0] == "PHASE" and len(c) >= 6:
            p = {"num": int(c[1]), "status": c[2], "attempt": c[3],
                 "gates": c[4].split(), "title": c[5], "tasks": []}
            phases.append(p)
            by_num[c[1]] = p
        elif c[0] == "TASK" and len(c) >= 5 and c[1] in by_num:
            by_num[c[1]]["tasks"].append({"i": int(c[2]), "status": c[3], "title": c[4]})

    # live.tsv vence para a fase corrente, mas nunca rebaixa task confirmada.
    try:
        with open(os.path.join(state_dir, "live.tsv"), encoding="utf-8") as f:
            live = f.read().splitlines()
    except OSError:
        live = []
    live_phase = None
    for line in live:
        c = line.split("\t")
        if c[0] == "PHASE" and len(c) >= 2:
            live_phase = by_num.get(c[1])
        elif c[0] == "ACTIVITY" and len(c) >= 2 and c[1]:
            meta["activity"] = c[1]
        elif c[0] == "LIVE" and len(c) >= 3 and live_phase:
            for t in live_phase["tasks"]:
                if str(t["i"]) == c[1] and t["status"] not in ("done", "incomplete"):
                    t["status"] = c[2]

    manifest = {}
    try:
        with open(os.path.join(phases_dir, "manifest.txt"), encoding="utf-8") as f:
            for line in f:
                if not line.startswith("#") and "|" in line:
                    file, num, _ = line.rstrip("\n").split("|", 2)
                    manifest[num] = file
    except OSError:
        pass

    now = time.time()
    for p in phases:
        n = str(p["num"])
        if meta.get(f"tdur_{n}"):
            p["duration"] = fmt_dur(int(meta[f"tdur_{n}"]))
        elif p["status"] == "running" and meta.get(f"tstart_{n}"):
            p["duration"] = fmt_dur(now - int(meta[f"tstart_{n}"]))
        else:
            p["duration"] = ""
        p["description"], p["files"] = phase_doc(phases_dir, manifest.get(n, ""))

    tasks = [t for p in phases for t in p["tasks"]]
    done_tasks = sum(t["status"] == "done" for t in tasks)
    return {
        "ok": True,
        "idle": False,
        "meta": meta,
        "counts": {
            "done_phases": sum(p["status"] == "done" for p in phases),
            "total_phases": len(phases),
            "done_tasks": done_tasks,
            "total_tasks": len(tasks),
            "pct": round(100 * done_tasks / len(tasks)) if tasks else 0,
        },
        "phases": phases,
    }


def make_handler(repo):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/":
                with open(os.path.join(HERE, "ralph-board.html"), "rb") as f:
                    body, ctype = f.read(), "text/html; charset=utf-8"
            elif path == "/state.json":
                body = json.dumps(read_state(repo), ensure_ascii=False).encode()
                ctype = "application/json; charset=utf-8"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass  # sem isso o terminal do run vira um GET por segundo

    return Handler


def main(argv):
    port, once, repo = 3847, False, "."
    it = iter(argv)
    for a in it:
        if a == "--once":
            once = True
        elif a == "--port":
            port = int(next(it))
        elif a.startswith("--port="):
            port = int(a.split("=", 1)[1])
        else:
            repo = a
    repo = os.path.abspath(repo)

    if once:
        print(json.dumps(read_state(repo), ensure_ascii=False, indent=2))
        return 0

    httpd = ThreadingHTTPServer(("127.0.0.1", port), make_handler(repo))
    print(f"ralph board: http://127.0.0.1:{port}  ({repo})", file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

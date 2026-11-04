SCRIPT RUNBOOK: CONTENTION -> RETRIEVAL-ONLY
============================================

Run from the repo root. Guardrails: no sed, no 2>/dev/null, no set -e,
no rm -rf, exits 0 or 2. All scripts print measured state first.

01 AUDIT CPU LOCK (read-only by default)
  ./scripts/01-audit-cpu-lock.sh
  ./scripts/01-audit-cpu-lock.sh --stress 10
  ./scripts/01-audit-cpu-lock.sh --firmware
  ./scripts/01-audit-cpu-lock.sh --apply-firmware --yes

  Reports governor/driver/min/max/current clocks, thermals, AC/battery,
  PSI, kernel power messages. --stress runs 8 busy loops and samples the
  clock; it exits 2 if every core stays below 1 GHz (platform/EC lock).

02 RELIEVE CONTENTION (never kills the dashboard)
  ./scripts/02-relieve-contention.sh
  ./scripts/02-relieve-contention.sh --dashboard-low
  ./scripts/02-relieve-contention.sh --cap opencode-grafana:0.5
  ./scripts/02-relieve-contention.sh --stop <container>
  ./scripts/02-relieve-contention.sh --dry-run --dashboard-low

  --dashboard-low renices/ionices the dashboard.mjs sidecar inside the
  opencode web container; it stays online. --cap uses docker update
  --cpus; --stop uses docker stop.

03 VERIFY LOCAL LLM
  ./scripts/03-verify-local-llm.sh --model qwen2.5:3b-instruct --warm
  ./scripts/03-verify-local-llm.sh --max-seconds 60

  Warms and times a short generation. --warm also loads the embedding
  model so phase 4 does not pay its ~20s cold load, and prints that
  measured time. Exits 2 if it exceeds --max-seconds or hits the hard
  timeout; suggests qwen2.5:0.5b-instruct. RAG_REQUEST_TIMEOUT defaults to
  120s: 5x the measured 20.6s cold load of nomic-embed-text on ws24.

04 RETRIEVAL ONLY
  ./scripts/04-retrieval-only.sh --query "What is the pet policy?" --top-k 3
  ./scripts/04-retrieval-only.sh --status

  Emits JSON chunks for a remote model (opencode / DeepSeek / Gemini) to
  synthesize the answer. No local generation.

07 I/O TRIAGE
  ./scripts/07-io-triage.sh
  ./scripts/07-io-triage.sh --stop-updatedb --yes
  ./scripts/07-io-triage.sh --dashboard-low-io
  ./scripts/07-io-triage.sh --rag

  Prints load/PSI/vmstat, indexers (updatedb/plocate/tracker/baloo),
  iotop/pidstat, docker stats/log driver/df, DB/WAL/log sizes, and
  /api/resources. --dashboard-low-io appends DASH_SSE_MS/DASH_SEGMENTS/
  DASH_AUTO_SHED to the harness .env.local; restart to apply.

08 GATED RECOVERY
  ./scripts/08-gated-recovery.sh --diagnose
  ./scripts/08-gated-recovery.sh --all --yes
  ./scripts/08-gated-recovery.sh --all --yes --restart-web
  ./scripts/08-gated-recovery.sh --push

  Host-only. Every assert fails closed with exit 2: host commands, repo
  identity, dashboard JSON, indexer stop, I/O threshold, dashboard keys,
  RAG venv/Ollama/model/store, runbook phases, and push (no commits ahead).
  Use --allow-high-io to override only the I/O threshold. Stopping an
  indexer needs passwordless sudo; otherwise the gate fails closed with
  the manual pkill command instead of waiting on a password prompt.
  --yes is forwarded to the runbook, so --all --yes also answers the
  phase-2 prompt and pauses grafana/dockge/mesh/paypal.

09 OLLAMA START
  ./scripts/09-ollama-start.sh
  ./scripts/09-ollama-start.sh --pull
  ./scripts/09-ollama-start.sh --status

  Prints systemd unit state, the :11434 listener, /api/tags, and models.
  Uses the unit when present (passwordless sudo required), otherwise starts
  `ollama serve` with OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=1
  OLLAMA_KEEP_ALIVE=5m, waits for the API, and verifies the chat and
  embedding models. Idempotent; --pull downloads missing models.

10 RECOVERY AUTOPILOT
  ./scripts/10-recovery-autopilot.sh
  ./scripts/10-recovery-autopilot.sh --max-attempts 4 --retry-sleep 30

  Runs 08 --all --yes under a watchdog that tees the full run to
  /tmp/recovery-autopilot.log and self-corrects known stalls: Ollama down
  or a model missing (09 --pull), embedding timeout/cold load (retry with
  the model now resident), I/O still high (wait + retry). It stops with
  the exact command when the blocker needs credentials (sudo pkill,
  gh auth). No terminal scraping; the wrapper owns the PTY.

11 HOST ACCESS
  ./scripts/11-host-access.sh --check
  ./scripts/11-host-access.sh --install --yes
  ./scripts/11-host-access.sh --cmd 'hostname; uptime -p'
  ./scripts/11-host-access.sh --list
  ./scripts/11-host-access.sh --screen [--window ID]

  Runs in the container: bootstraps a local ssh client (apt download +
  extract, no root), a dedicated container key, and host authorization.
  --cmd executes on the host; --list/--screen capture a host window and
  OCR it (fallback). tmux is the primary monitor: --tmux-new, --tmux-exec,
  --tmux-capture (exact text), --tmux-send (literal text + Enter),
  --tmux-kill. The private key is never printed. Revoke with: remove the
  opencode-container line from the host authorized_keys.

MCP (RETRIEVAL ONLY)
  ./scripts/rag-mcp.sh --self-test
  ./scripts/rag-mcp.sh

  Tools: search_docs(query, top_k), status.
  opencode config (preserve existing keys):
    "mcp": {
      "servers": {
        "rag": {
          "type": "local",
          "command": ["/abs/path/production-local-rag/.venv/bin/python", "src/mcp_server.py"],
          "cwd": "/abs/path/production-local-rag",
          "environment": { "RAG_OLLAMA_BASE_URL": "http://192.168.4.24:11434" }
        }
      }
    }

  The server must run where the venv/deps and Ollama are reachable. The
  opencode container cannot execute a host-only Python 3.12 venv; install
  3.12+deps in the container or run a remote MCP gateway.

DASHBOARD RESOURCE/SEGMENT CONTROLS (harness image)
  DASH_SEGMENTS=cost,activity,todos   default; drop a segment to reduce CPU
  DASH_SSE_MS=5000                    live refresh interval
  DASH_AUTO_SHED=1                    drop activity when CPU PSI > 30
  GET /api/resources                  JSON: cgroup, PSI, RSS, SSE clients
  The nav shows "cpu <psi>% rss <MB> live <n>" refreshed every 10s.

  The dashboard stays enabled; these are toggles, not opt-outs.

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

  Warms and times a short generation. Exits 2 if it exceeds --max-seconds
  or hits the hard timeout; suggests qwen2.5:0.5b-instruct.

04 RETRIEVAL ONLY
  ./scripts/04-retrieval-only.sh --query "What is the pet policy?" --top-k 3
  ./scripts/04-retrieval-only.sh --status

  Emits JSON chunks for a remote model (opencode / DeepSeek / Gemini) to
  synthesize the answer. No local generation.

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

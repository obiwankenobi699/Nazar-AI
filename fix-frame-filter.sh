cat > /mnt/user-data/outputs/nazar-health-check.sh << 'MAINSCRIPT'
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# nazar-health-check.sh — Nazar AI full system health check
# Checks every connection, service, file, and config
# Updates context/ folder with fresh reports
#
# Run from project root: bash nazar-health-check.sh
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

REPORT_DIR="context"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
REPORT_FILE="$REPORT_DIR/SYSTEM_REPORT.md"
CONTEXT_FILE="$REPORT_DIR/PROJECT_CONTEXT.md"
CODEMAP_FILE="$REPORT_DIR/CODEMAP.txt"

mkdir -p "$REPORT_DIR"

# ── Colors ────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✅${NC} $1"; }
fail() { echo -e "  ${RED}❌${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠️ ${NC} $1"; }
info() { echo -e "  ${BLUE}ℹ️ ${NC} $1"; }

# Track overall status
PASS=0
FAIL=0
WARN=0

ok()   { PASS=$((PASS+1)); pass "$1"; }
bad()  { FAIL=$((FAIL+1)); fail "$1"; }
caution() { WARN=$((WARN+1)); warn "$1"; }

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Nazar AI — System Health Check"
echo "  $TIMESTAMP"
echo "══════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════
# 1. PROJECT ROOT CHECK
# ════════════════════════════════════════════════════════════════════
echo ""
echo "── 1. Project structure"

for f in \
  "package.json" \
  "next.config.ts" \
  ".env" \
  "lib/frame-filter.ts" \
  "lib/tensorflow-loader.ts" \
  "app/pages/realtimeStreamPage/page.tsx" \
  "app/pages/realtimeStreamPage/actions.ts" \
  "app/api/embed/route.ts" \
  "app/api/search/route.ts" \
  "app/pages/search/page.tsx" \
  "scripts/embedder.py" \
  "scripts/start-embedder.sh" \
  "scripts/.venv/bin/activate" \
  "components/header-nav.tsx"
do
  if [ -f "$f" ]; then ok "$f"; else bad "$f MISSING"; fi
done

# ChromaDB dir
if [ -d "scripts/.chromadb" ]; then
  FRAME_COUNT=$(python3 -c "
import sys
sys.path.insert(0, 'scripts/.venv/lib/python3.13/site-packages')
sys.path.insert(0, 'scripts/.venv/lib/python3.12/site-packages')
sys.path.insert(0, 'scripts/.venv/lib/python3.11/site-packages')
try:
    import chromadb
    c = chromadb.PersistentClient(path='scripts/.chromadb')
    col = c.get_or_create_collection('nazar_frames')
    print(col.count())
except Exception as e:
    print(f'err:{e}')
" 2>/dev/null || echo "unknown")
  ok "scripts/.chromadb (frames indexed: $FRAME_COUNT)"
else
  caution "scripts/.chromadb not found — will be created on first embed"
fi

# ════════════════════════════════════════════════════════════════════
# 2. ENV VARIABLES
# ════════════════════════════════════════════════════════════════════
echo ""
echo "── 2. Environment variables"

if [ -f ".env" ]; then
  check_env() {
    local key="$1"
    local val
    val=$(grep "^${key}=" .env 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    if [ -z "$val" ] || [ "$val" = "" ] || [[ "$val" == *"your_"* ]] || [[ "$val" == *"YOUR_"* ]]; then
      bad "$key — NOT SET or placeholder"
    else
      local preview="${val:0:8}..."
      ok "$key = $preview"
    fi
  }
  check_env "OPENAI_API_KEY"
  check_env "NEXT_PUBLIC_SUPABASE_URL"
  check_env "NEXT_PUBLIC_SUPABASE_ANON_KEY"
  # Optional ones
  for opt in "TELEGRAM_BOT_TOKEN" "TELEGRAM_CHAT_ID" "RESEND_API_KEY" "TWILIO_ACCOUNT_SID"; do
    val=$(grep "^${opt}=" .env 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
    if [ -z "$val" ]; then
      caution "$opt — not set (optional)"
    else
      ok "$opt = ${val:0:8}..."
    fi
  done
else
  bad ".env file missing"
fi

# ════════════════════════════════════════════════════════════════════
# 3. OLLAMA
# ════════════════════════════════════════════════════════════════════
echo ""
echo "── 3. Ollama"

if command -v ollama &>/dev/null; then
  OLLAMA_VER=$(ollama --version 2>/dev/null || echo "unknown")
  ok "Ollama installed: $OLLAMA_VER"
else
  bad "Ollama NOT installed — run: curl -fsSL https://ollama.com/install.sh | sh"
fi

if pgrep -x ollama &>/dev/null; then
  ok "Ollama process running"
else
  caution "Ollama not running — start with: ollama serve &"
fi

# Check model
if command -v ollama &>/dev/null; then
  if ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
    ok "nomic-embed-text model available"
  else
    bad "nomic-embed-text NOT pulled — run: ollama pull nomic-embed-text"
  fi

  # Test actual embedding
  EMB_TEST=$(curl -s -X POST http://localhost:11434/api/embeddings \
    -H 'Content-Type: application/json' \
    -d '{"model":"nomic-embed-text","prompt":"test"}' \
    --max-time 5 2>/dev/null || echo "")
  if echo "$EMB_TEST" | grep -q '"embedding"'; then
    DIM=$(echo "$EMB_TEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('embedding',[])))" 2>/dev/null || echo "?")
    ok "Ollama embedding API working — dims: $DIM"
  else
    bad "Ollama embedding API not responding at localhost:11434"
  fi
fi

# ════════════════════════════════════════════════════════════════════
# 4. EMBEDDER SERVER
# ════════════════════════════════════════════════════════════════════
echo ""
echo "── 4. Embedder server (localhost:8000)"

STATS=$(curl -s http://localhost:8000/stats --max-time 3 2>/dev/null || echo "")
if echo "$STATS" | grep -q '"total_frames"'; then
  FRAMES=$(echo "$STATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_frames',0))" 2>/dev/null || echo "?")
  MODEL=$(echo "$STATS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model','?'))" 2>/dev/null || echo "?")
  ok "Embedder running — frames: $FRAMES, model: $MODEL"
else
  bad "Embedder NOT running at localhost:8000"
  info "Start it: cd scripts && ./start-embedder.sh"
fi

# Test embed endpoint
EMBED_TEST=$(curl -s -X POST http://localhost:8000/embed \
  -H 'Content-Type: application/json' \
  -d '{"imageBase64":"data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMCwsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/wAAUCAACAAIDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwABmX/9k=","timestamp":"00:01","cameraId":"test"}' \
  --max-time 10 2>/dev/null || echo "")
if echo "$EMBED_TEST" | grep -q '"stored"'; then
  ok "Embed endpoint working"
else
  caution "Embed endpoint test failed (embedder may be offline)"
fi

# Test search endpoint
SEARCH_TEST=$(curl -s -X POST http://localhost:8000/search \
  -H 'Content-Type: application/json' \
  -d '{"query":"person standing","topK":3}' \
  --max-time 10 2>/dev/null || echo "")
if echo "$SEARCH_TEST" | grep -q '"results"'; then
  RESULT_COUNT=$(echo "$SEARCH_TEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('results',[])))" 2>/dev/null || echo "?")
  ok "Search endpoint working — got $RESULT_COUNT results"
else
  caution "Search endpoint test failed (embedder may be offline)"
fi

# ════════════════════════════════════════════════════════════════════
# 5. NEXT.JS API ROUTES
# ════════════════════════════════════════════════════════════════════
echo ""
echo "── 5. Next.js API routes (localhost:3000)"

NEXTJS_UP=$(curl -s http://localhost:3000 --max-time 3 2>/dev/null && echo "yes" || echo "no")
if [ "$NEXTJS_UP" = "yes" ]; then
  ok "Next.js running at localhost:3000"

  for route in \
    "/api/search" \
    "/pages/search" \
    "/pages/realtimeStreamPage"
  do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3000${route}" --max-time 5 2>/dev/null || echo "000")
    if [ "$STATUS" = "200" ] || [ "$STATUS" = "307" ]; then
      ok "GET $route → $STATUS"
    elif [ "$STATUS" = "503" ]; then
      caution "GET $route → $STATUS (embedder offline)"
    else
      bad "GET $route → $STATUS"
    fi
  done
else
  caution "Next.js not running at localhost:3000 (start: npm run dev)"
fi

# ════════════════════════════════════════════════════════════════════
# 6. PYTHON PACKAGES
# ════════════════════════════════════════════════════════════════════
echo ""
echo "── 6. Python packages"

if [ -f "scripts/.venv/bin/python" ]; then
  ok "Python virtualenv exists"
  VENV_PY="scripts/.venv/bin/python"
  for pkg in fastapi uvicorn chromadb ollama PIL; do
    if "$VENV_PY" -c "import $pkg" 2>/dev/null; then
      VER=$("$VENV_PY" -c "import $pkg; print(getattr($pkg,'__version__','ok'))" 2>/dev/null || echo "ok")
      ok "$pkg ($VER)"
    else
      bad "$pkg NOT installed in venv"
    fi
  done
else
  bad "Python venv not found at scripts/.venv"
  info "Run: cd scripts && python -m venv .venv && source .venv/bin/activate && pip install fastapi uvicorn chromadb ollama pillow"
fi

# ════════════════════════════════════════════════════════════════════
# 7. FRAME FILTER CONFIG
# ════════════════════════════════════════════════════════════════════
echo ""
echo "── 7. Frame filter config (lib/frame-filter.ts)"

if [ -f "lib/frame-filter.ts" ]; then
  grep_val() {
    grep -o "${1}:.*" lib/frame-filter.ts | head -1 | grep -o '[0-9.]*' | head -1
  }

  ANOMALY=$(grep_val "anomalyThreshold")
  MOTION=$(grep_val "motionThreshold")
  WARMUP=$(grep_val "warmupMs")
  COOLDOWN=$(grep_val "cooldownMs")

  info "anomalyThreshold: $ANOMALY (target ≤25)"
  info "motionThreshold:  $MOTION (target ≤0.03)"
  info "warmupMs:         $WARMUP (target ≤2000)"
  info "cooldownMs:       $COOLDOWN"

  [ "${ANOMALY:-99}" -le 25 ] 2>/dev/null && ok "anomalyThreshold OK" || caution "anomalyThreshold may be too high (${ANOMALY})"
fi

# ════════════════════════════════════════════════════════════════════
# 8. GIT STATUS
# ════════════════════════════════════════════════════════════════════
echo ""
echo "── 8. Git status"

if git rev-parse --git-dir &>/dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
  UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  ok "Git repo on branch: $BRANCH"
  if [ "$UNCOMMITTED" -gt 0 ]; then
    caution "$UNCOMMITTED uncommitted changes"
    git status --short 2>/dev/null | head -10 | while read line; do info "  $line"; done
  else
    ok "Working tree clean"
  fi
fi

# ════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Summary: ✅ $PASS passed  ❌ $FAIL failed  ⚠️  $WARN warnings"
echo "══════════════════════════════════════════════════════════"

# ════════════════════════════════════════════════════════════════════
# WRITE REPORTS TO context/
# ════════════════════════════════════════════════════════════════════
echo ""
echo "── Writing reports to context/..."

# ── SYSTEM_REPORT.md ─────────────────────────────────────────────
cat > "$REPORT_FILE" << MDEOF
# Nazar AI — System Report
Generated: $TIMESTAMP

## Status
- ✅ Passed: $PASS
- ❌ Failed: $FAIL
- ⚠️  Warnings: $WARN

## Pipeline
\`\`\`
Camera (Webcam)
  ↓
MoveNet + BlazeFace (TensorFlow.js, browser)
  ↓
Frame Filter (lib/frame-filter.ts)
  ├── anomalyThreshold: $(grep -o 'anomalyThreshold:.*' lib/frame-filter.ts | head -1 | grep -o '[0-9.]*' | head -1)
  ├── motionThreshold:  $(grep -o 'motionThreshold:.*' lib/frame-filter.ts | head -1 | grep -o '[0-9.]*' | head -1)
  ├── warmupMs:         $(grep -o 'warmupMs:.*' lib/frame-filter.ts | head -1 | grep -o '[0-9.]*' | head -1)
  └── cooldownMs:       $(grep -o 'cooldownMs:.*' lib/frame-filter.ts | head -1 | grep -o '[0-9.]*' | head -1)
  ↓
  ├── [ALERT path] GPT-4o-mini (OpenAI Vision) → Timestamp → Alerts
  │     Telegram / Email / WhatsApp
  │
  └── [SEARCH path] Every 4th frame → /api/embed → embedder.py
        Ollama nomic-embed-text → ChromaDB (scripts/.chromadb/)
          ↓
        /pages/search → semantic search UI
\`\`\`

## Services
| Service | URL | Status |
|---------|-----|--------|
| Next.js | http://localhost:3000 | $(curl -s http://localhost:3000 --max-time 2 &>/dev/null && echo "🟢 Running" || echo "🔴 Stopped") |
| Embedder | http://localhost:8000 | $(curl -s http://localhost:8000/stats --max-time 2 &>/dev/null && echo "🟢 Running" || echo "🔴 Stopped") |
| Ollama | http://localhost:11434 | $(curl -s http://localhost:11434/api/tags --max-time 2 &>/dev/null && echo "🟢 Running" || echo "🔴 Stopped") |

## Vector DB
- Location: \`scripts/.chromadb/\`
- Collection: \`nazar_frames\`
- Frames indexed: $(python3 -c "
import sys
for p in ['scripts/.venv/lib/python3.13/site-packages','scripts/.venv/lib/python3.12/site-packages','scripts/.venv/lib/python3.11/site-packages']:
    sys.path.insert(0, p)
try:
    import chromadb
    c = chromadb.PersistentClient(path='scripts/.chromadb')
    col = c.get_or_create_collection('nazar_frames')
    print(col.count())
except:
    print('embedder not running')
" 2>/dev/null || echo "unknown")
- Embedding model: nomic-embed-text (768 dims, local, free)
- Max capacity: 2000 frames (auto-pruned)

## Key Files
| File | Purpose |
|------|---------|
| \`lib/frame-filter.ts\` | 3-layer smart filter (motion → anomaly → cooldown) |
| \`lib/tensorflow-loader.ts\` | TF.js loader (BlazeFace + MoveNet) |
| \`app/pages/realtimeStreamPage/page.tsx\` | Main surveillance engine |
| \`app/pages/realtimeStreamPage/actions.ts\` | GPT-4o-mini vision call |
| \`scripts/embedder.py\` | FastAPI server, Ollama embeddings, ChromaDB |
| \`app/api/embed/route.ts\` | Proxy: Next.js → embedder |
| \`app/api/search/route.ts\` | Proxy: Next.js → embedder search |
| \`app/pages/search/page.tsx\` | Semantic search UI |

## Environment
- Node: $(node --version 2>/dev/null || echo "unknown")
- Python: $(python3 --version 2>/dev/null || echo "unknown")
- Next.js: $(cat package.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dependencies',{}).get('next','unknown'))" 2>/dev/null || echo "unknown")
- OS: $(uname -srm)

## API Routes
$(find app/api -name "route.ts" 2>/dev/null | sort | while read f; do echo "- \`$f\`"; done)

## To-Do / Known Issues
- [ ] Timestamp shows 00:00 from GPT — run fix-timestamp-prompt.sh
- [ ] maxFaces: 1 in BlazeFace — only 1 face detected per frame
- [ ] SINGLEPOSE_LIGHTNING — only 1 person tracked (MoveNet limit)
- [ ] LocalStorage for saved videos — should move to Supabase Storage
- [ ] No camera registry (no camera_id, location, RTSP URL table)
MDEOF

ok "context/SYSTEM_REPORT.md written"

# ── PROJECT_CONTEXT.md ────────────────────────────────────────────
cat > "$CONTEXT_FILE" << MDEOF
# Nazar AI — Project Context
Generated: $TIMESTAMP

## Tech Stack
- **Frontend**: Next.js 15, React, TypeScript, Tailwind CSS
- **AI (Alerts)**: GPT-4o-mini (OpenAI Vision API) via server actions
- **AI (Search)**: Ollama nomic-embed-text (local, 768-dim)
- **ML (Browser)**: TensorFlow.js — BlazeFace + MoveNet SINGLEPOSE_LIGHTNING
- **Vector DB**: ChromaDB (local, persisted at scripts/.chromadb/)
- **Auth**: Supabase
- **Alerts**: Telegram, Email (Resend), WhatsApp (Twilio)

## Architecture
\`\`\`
Browser
  └── Webcam → TF.js (BlazeFace + MoveNet)
        └── Frame Filter (lib/frame-filter.ts)
              ├── ALERT path (score ≥ 22 OR 30s elapsed)
              │     └── GPT-4o-mini → Timeline → Telegram/Email/WhatsApp
              └── SEARCH path (every 4th frame, person detected)
                    └── POST /api/embed → embedder.py
                          └── Ollama embed → ChromaDB

Python Server (scripts/embedder.py @ :8000)
  ├── POST /embed   — store frame embedding
  ├── POST /search  — semantic search
  ├── GET  /stats   — collection info
  └── DELETE /clear — wipe collection
\`\`\`

## Key Pages
| Route | Description |
|-------|-------------|
| \`/pages/realtimeStreamPage\` | Live surveillance + detection |
| \`/pages/search\` | Semantic search over footage |
| \`/pages/saved-videos\` | Browse saved recordings |
| \`/pages/statistics\` | Event statistics |
| \`/pages/upload\` | Upload video for analysis |

## Frame Filter Thresholds (lib/frame-filter.ts)
\`\`\`
anomalyThreshold: 22    # GPT fires above this score
motionThreshold:  0.02  # fraction of pixels that must change
warmupMs:         1500  # ignore first 1.5s of recording
cooldownMs:       6000  # min ms between GPT calls
fallFramesRequired: 2   # consecutive body-low frames = fall
\`\`\`

## Scoring Logic
\`\`\`
relativeMotion × 12  → max 30 pts
suddenMovement       → +25 pts
likelyFall           → +45 pts
bodyLow (partial)    → +25 pts
noFaceButBody        → +18 pts
audioKeyword         → +30 pts
poseCount < 5        → +10 pts
\`\`\`

## Services
| Service | URL | Notes |
|---------|-----|-------|
| Next.js | :3000 | npm run dev |
| Embedder | :8000 | bash scripts/start-embedder.sh |
| Ollama | :11434 | auto-started by embedder script |

## File Map
\`\`\`
NAZAR_AI/
├── app/
│   ├── pages/
│   │   ├── realtimeStreamPage/
│   │   │   ├── page.tsx      ← Main surveillance engine
│   │   │   └── actions.ts    ← GPT-4o-mini vision call
│   │   ├── search/
│   │   │   └── page.tsx      ← Semantic search UI [NEW]
│   │   ├── saved-videos/
│   │   ├── statistics/
│   │   └── upload/
│   ├── api/
│   │   ├── embed/route.ts    ← Proxy to embedder [NEW]
│   │   ├── search/route.ts   ← Proxy to embedder [NEW]
│   │   ├── analyze/route.ts
│   │   ├── chat/route.ts
│   │   ├── send-telegram/
│   │   ├── send-email/
│   │   └── send-whatsapp/
│   └── layout.tsx
├── lib/
│   ├── frame-filter.ts       ← Smart 3-layer filter [CORE]
│   └── tensorflow-loader.ts
├── components/
│   ├── header-nav.tsx
│   ├── chat-interface.tsx
│   ├── timestamp-list.tsx
│   └── Timeline.tsx
├── scripts/
│   ├── embedder.py           ← FastAPI + ChromaDB + Ollama [NEW]
│   ├── start-embedder.sh     ← Start command [NEW]
│   ├── .chromadb/            ← Persisted vector DB [NEW]
│   └── .venv/                ← Python virtualenv [NEW]
└── context/
    ├── SYSTEM_REPORT.md      ← This health check output
    ├── PROJECT_CONTEXT.md    ← This file
    └── CODEMAP.txt           ← File map
\`\`\`

## Known Limitations
1. BlazeFace maxFaces: 1 — only detects 1 face per frame
2. MoveNet SINGLEPOSE — only tracks 1 person
3. Browser-based detection — closing tab stops surveillance
4. No RTSP/IP camera support yet
5. Videos saved to localStorage (should use Supabase Storage)

## Next Steps (Phase 2)
- [ ] Move to MULTIPOSE_THUNDER for multi-person tracking
- [ ] Add RTSP camera support via Node.js worker
- [ ] Move event storage to Supabase events table
- [ ] Add camera registry (camera_id, location, url)
- [ ] Add ring buffer for pre/post event capture
MDEOF

ok "context/PROJECT_CONTEXT.md updated"

# ── CODEMAP.txt ────────────────────────────────────────────────────
{
echo "================================"
echo "NAZAR AI CODEMAP"
echo "Generated: $TIMESTAMP"
echo "================================"
echo ""

echo "=== SOURCE FILES ==="
find . -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.py" \) \
  -not -path "*/node_modules/*" \
  -not -path "*/.next/*" \
  -not -path "*/.venv/*" \
  -not -path "*/dist/*" \
  -not -name "*.bak*" \
  | sort \
  | while read f; do
    lines=$(wc -l < "$f" 2>/dev/null || echo "?")
    echo "$f ($lines lines)"
  done

echo ""
echo "=== API ROUTES ==="
find app/api -name "route.ts" 2>/dev/null | sort

echo ""
echo "=== SCRIPTS ==="
find scripts -name "*.py" -o -name "*.sh" 2>/dev/null | grep -v ".venv" | sort

echo ""
echo "=== VECTOR DB ==="
if [ -d "scripts/.chromadb" ]; then
  du -sh scripts/.chromadb 2>/dev/null | awk '{print "Size: " $1}'
  python3 -c "
import sys
for p in ['scripts/.venv/lib/python3.13/site-packages','scripts/.venv/lib/python3.12/site-packages','scripts/.venv/lib/python3.11/site-packages']:
    sys.path.insert(0, p)
try:
    import chromadb
    c = chromadb.PersistentClient(path='scripts/.chromadb')
    col = c.get_or_create_collection('nazar_frames')
    print('Frames:', col.count())
except Exception as e:
    print('Cannot read:', e)
" 2>/dev/null
else
  echo "Not created yet"
fi

echo ""
echo "=== FRAME FILTER CONFIG ==="
if [ -f "lib/frame-filter.ts" ]; then
  grep -E "(anomalyThreshold|motionThreshold|warmupMs|cooldownMs|fallFrames)" lib/frame-filter.ts | grep -v "//"
fi

echo ""
echo "=== PACKAGE VERSIONS ==="
node --version 2>/dev/null | xargs -I{} echo "Node: {}"
python3 --version 2>/dev/null
cat package.json | python3 -c "
import sys, json
d = json.load(sys.stdin)
deps = {**d.get('dependencies',{}), **d.get('devDependencies',{})}
for k in ['next','react','typescript','openai']:
    if k in deps: print(f'{k}: {deps[k]}')
" 2>/dev/null

} > "$CODEMAP_FILE"

ok "context/CODEMAP.txt updated"

# ════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════"
printf "  Result: ${GREEN}✅ %d passed${NC}  ${RED}❌ %d failed${NC}  ${YELLOW}⚠️  %d warnings${NC}\n" $PASS $FAIL $WARN
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Reports written to context/:"
echo "    context/SYSTEM_REPORT.md"
echo "    context/PROJECT_CONTEXT.md"
echo "    context/CODEMAP.txt"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "  ❌ Fix the failed items above before using the system."
elif [ "$WARN" -gt 0 ]; then
  echo "  ⚠️  System mostly working. Review warnings above."
else
  echo "  ✅ All systems go."
fi
echo ""
MAINSCRIPT

chmod +x /mnt/user-data/outputs/nazar-health-check.sh
echo "Done"
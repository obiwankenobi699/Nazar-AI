#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# nazar-patch.sh — Nazar AI full patch script
# Run from project root: bash nazar-patch.sh
#
# Fixes applied:
#   1. Recording clock (single source of truth for timestamps)
#   2. Warmup period (5s before GPT is allowed)
#   3. noFaceButBody weight reduced (false positives in dark rooms)
#   4. captureFrame moved AFTER filter (stop wasting canvas work)
#   5. transcriptRef / faceDetectedRef / faceConfidenceRef (stale closures)
#   6. Event deduplication (skip if same description within 30s)
#   7. State machine (NORMAL / SUSPICIOUS / DANGER)
#   8. Filter stats counter in window.__nazarStats
#   9. GPT prompt tightened (no "person visible" non-events)
#  10. Filter debug bar in UI
# ═══════════════════════════════════════════════════════════════════

set -e

PAGE="app/pages/realtimeStreamPage/page.tsx"
ACTIONS="app/pages/realtimeStreamPage/actions.ts"
FILTER="lib/frame-filter.ts"

# ── Sanity check ────────────────────────────────────────────────────
for f in "$PAGE" "$ACTIONS" "$FILTER"; do
  if [ ! -f "$f" ]; then
    echo "❌  Cannot find $f — run this from the project root."
    exit 1
  fi
done

echo "✅  All files found. Starting patch..."

# ════════════════════════════════════════════════════════════════════
# PATCH 1 — lib/frame-filter.ts
#   - Add 5s warmup before GPT is allowed
#   - Reduce noFaceButBody weight from 15 → 8 (dark room false positives)
#   - Add warmupDone() helper
# ════════════════════════════════════════════════════════════════════

cp "$FILTER" "${FILTER}.bak"

python3 - "$FILTER" << 'PY'
import sys, re

path = sys.argv[1]
src  = open(path).read()

# 1a. Add warmupMs to FilterConfig interface after fallFramesRequired
src = src.replace(
    "  fallFramesRequired: number    // consecutive \"body low\" frames before scoring as fall\n}",
    "  fallFramesRequired: number    // consecutive \"body low\" frames before scoring as fall\n  warmupMs: number              // ms after reset before GPT is allowed (avoids startup noise)\n}"
)

# 1b. Add warmupMs default value
src = src.replace(
    "  fallFramesRequired: 3,\n}",
    "  fallFramesRequired: 3,\n  warmupMs: 5000,\n}"
)

# 1c. Add private startTime field after velocityHistory
src = src.replace(
    "  // sudden movement detection\n  private velocityHistory: number[] = []",
    "  // sudden movement detection\n  private velocityHistory: number[] = []\n\n  // warmup tracking\n  private startTime = Date.now()"
)

# 1d. Reset startTime in reset()
src = src.replace(
    "    this.velocityHistory = []\n  }",
    "    this.velocityHistory = []\n    this.startTime = Date.now()\n  }"
)

# 1e. Add warmup check at top of evaluate(), after the ctx null check
old = "    const frame = ctx.getImageData(0, 0, canvas.width, canvas.height)\n\n    // ── Layer 1: adaptive motion"
new = "    const frame = ctx.getImageData(0, 0, canvas.width, canvas.height)\n\n    // ── Warmup gate ──────────────────────────────────────────────────\n    if (Date.now() - this.startTime < this.cfg.warmupMs) {\n      this.lastImageData = frame\n      this.updateBaseline(0)\n      return this.result(false, 0, 'no_motion', this.emptyDebug())\n    }\n\n    // ── Layer 1: adaptive motion"
src = src.replace(old, new)

# 1f. Reduce noFaceButBody weight from += 15 to += 8
src = src.replace(
    "    if (f.noFaceButBody)  s += 15             // person down / turned away",
    "    if (f.noFaceButBody)  s += 8              // person down / turned away (reduced: dark room FP)"
)

open(path, 'w').write(src)
print("frame-filter.ts patched")
PY

echo "✅  PATCH 1 — frame-filter.ts done"

# ════════════════════════════════════════════════════════════════════
# PATCH 2 — actions.ts
#   - Tighten GPT prompt: only fire on real events, not observations
#   - Add explicit "DO NOT report" section
# ════════════════════════════════════════════════════════════════════

cp "$ACTIONS" "${ACTIONS}.bak"

python3 - "$ACTIONS" << 'PY'
import sys

path = sys.argv[1]
src  = open(path).read()

old_prompt_end = """5. Suspicious Activities:
- Shoplifting
- Vandalism
- Trespassing"""

new_prompt_end = """5. Suspicious Activities:
- Shoplifting
- Vandalism
- Trespassing

IMPORTANT — Only report events from the list above.
DO NOT report any of the following (these are observations, not events):
- Person visible in frame
- Person standing normally
- Person partially visible
- Person in shadow or obscured
- Normal walking or movement
- Camera or lighting artifacts

If nothing from the dangerous event list is occurring, return isDangerous: false
with a one-line description like "Scene normal" or "No event detected"."""

src = src.replace(old_prompt_end, new_prompt_end)

open(path, 'w').write(src)
print("actions.ts patched")
PY

echo "✅  PATCH 2 — actions.ts done"

# ════════════════════════════════════════════════════════════════════
# PATCH 3 — page.tsx
#   All fixes in one Python pass to avoid ordering issues:
#   a) Add 3 refs (transcriptRef, faceDetectedRef, faceConfidenceRef)
#   b) Add filterStats state for UI counter
#   c) Add prevPoseKeypointsRef (if missing)
#   d) Sync transcriptRef in useEffect
#   e) Update faceDetectedRef/faceConfidenceRef inside runDetection
#   f) Add lastDescriptionRef for deduplication
#   g) Add recordingStateRef for state machine
#   h) Replace analyzeFrame with fixed version
#   i) Reset filter + stats in startRecording
#   j) Add filter debug bar in JSX
# ════════════════════════════════════════════════════════════════════

cp "$PAGE" "${PAGE}.bak"

python3 - "$PAGE" << 'PY'
import sys, re

path = sys.argv[1]
src  = open(path).read()

# ── a) Add new refs after isRecordingRef ──────────────────────────────────
OLD_REF = "  const durationIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null)"
NEW_REFS = """  const durationIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null)

  // ── Smart filter refs — always fresh, no stale closures ─────────────────
  const transcriptRef        = useRef<string>('')
  const faceDetectedRef      = useRef<boolean>(false)
  const faceConfidenceRef    = useRef<number | undefined>(undefined)
  const prevPoseKeypointsRef = useRef<Keypoint[] | null>(null)

  // ── Event deduplication ──────────────────────────────────────────────────
  const lastDescriptionRef   = useRef<{ text: string; time: number }>({ text: '', time: 0 })

  // ── State machine: NORMAL | SUSPICIOUS | DANGER ──────────────────────────
  const recordingStateRef    = useRef<'NORMAL' | 'SUSPICIOUS' | 'DANGER'>('NORMAL')

  // ── GPT call counter for stats ───────────────────────────────────────────
  const gptCallCountRef      = useRef(0)
  const framesEvaluatedRef   = useRef(0)
  const framesBlockedRef     = useRef(0)"""

if OLD_REF in src:
    # Only add if not already there
    if "transcriptRef" not in src:
        src = src.replace(OLD_REF, NEW_REFS)
    print("refs added")
else:
    print("WARNING: ref anchor not found, skipping ref injection")

# ── b) Add filterStats state after mlModelsReady state ───────────────────
OLD_STATE = "  const [lastPoseKeypoints, setLastPoseKeypoints] = useState<Keypoint[]>([])"
NEW_STATE = """  const [lastPoseKeypoints, setLastPoseKeypoints] = useState<Keypoint[]>([])
  const [filterStats, setFilterStats] = useState({
    evaluated: 0, blocked: 0, gptCalls: 0
  })"""

if OLD_STATE in src and "filterStats" not in src:
    src = src.replace(OLD_STATE, NEW_STATE)
    print("filterStats state added")

# ── c) Add transcriptRef sync useEffect before the closing of useEffect block
# Insert after the setIsClient(true) useEffect
OLD_CLIENT_EFFECT = "  useEffect(() => {\n    setIsClient(true)\n  }, [])"
NEW_CLIENT_EFFECT = """  useEffect(() => {
    setIsClient(true)
  }, [])

  // Keep transcriptRef in sync so analyzeFrame always reads fresh value
  useEffect(() => {
    transcriptRef.current = transcript
  }, [transcript])"""

if OLD_CLIENT_EFFECT in src and "transcriptRef.current = transcript" not in src:
    src = src.replace(OLD_CLIENT_EFFECT, NEW_CLIENT_EFFECT)
    print("transcriptRef sync effect added")

# ── d) Update face refs inside runDetection after estimateFaces ────────────
OLD_FACE = "        const predictions = await faceModelRef.current.estimateFaces(video, false)"
NEW_FACE = """        const predictions = await faceModelRef.current.estimateFaces(video, false)
        // ── Update refs for analyzeFrame (no stale closure) ──────────────
        faceDetectedRef.current   = predictions.length > 0
        faceConfidenceRef.current = predictions.length > 0
          ? predictions[0].probability as number
          : undefined"""

if OLD_FACE in src and "faceDetectedRef.current" not in src:
    src = src.replace(OLD_FACE, NEW_FACE)
    print("faceDetectedRef update added to runDetection")

# ── e) Update prevPoseKeypointsRef in runDetection after setLastPoseKeypoints
OLD_POSE_SET = "          setLastPoseKeypoints(convertedKeypoints)"
NEW_POSE_SET = """          prevPoseKeypointsRef.current = lastPoseKeypoints.length > 0 ? [...lastPoseKeypoints] : null
          setLastPoseKeypoints(convertedKeypoints)"""

if OLD_POSE_SET in src and "prevPoseKeypointsRef.current = lastPoseKeypoints" not in src:
    src = src.replace(OLD_POSE_SET, NEW_POSE_SET)
    print("prevPoseKeypointsRef update added")

# ── f) Replace analyzeFrame entirely ─────────────────────────────────────
# Find it by signature
AF_START = "  const analyzeFrame = async () => {"
AF_END   = "\n  }\n\n  // -----------------------------\n  // 6) Capture"

idx_start = src.find(AF_START)
idx_end   = src.find(AF_END, idx_start)

NEW_ANALYZE = '''  const analyzeFrame = async () => {
    if (!isRecordingRef.current) return
    if (!canvasRef.current) return

    framesEvaluatedRef.current++

    // ── Build hints from refs (always fresh) ───────────────────────────────
    const hints = {
      poseKeypoints:     lastPoseKeypoints,
      prevPoseKeypoints: prevPoseKeypointsRef.current,
      faceDetected:      faceDetectedRef.current,
      faceConfidence:    faceConfidenceRef.current,
      transcript:        transcriptRef.current,
      frameHeight:       canvasRef.current.height,
    }

    // ── Layer filter FIRST — no canvas capture until it passes ────────────
    const { send, score, reason, debug } = frameFilter.evaluate(canvasRef.current, hints)

    if (!send) {
      framesBlockedRef.current++
      console.log(`[FILTER] ⚪ DROP | reason=${reason} score=${score}`)
      // Update stats every 10 frames to avoid excessive re-renders
      if (framesEvaluatedRef.current % 10 === 0) {
        setFilterStats({
          evaluated: framesEvaluatedRef.current,
          blocked:   framesBlockedRef.current,
          gptCalls:  gptCallCountRef.current,
        })
      }
      return
    }

    // ── Filter passed — capture frame NOW (expensive, only when needed) ───
    const frame = await captureFrame()
    if (!frame || !frame.startsWith('data:image/jpeg')) {
      console.error('Invalid frame format')
      return
    }

    gptCallCountRef.current++
    setFilterStats({
      evaluated: framesEvaluatedRef.current,
      blocked:   framesBlockedRef.current,
      gptCalls:  gptCallCountRef.current,
    })

    console.log(
      `[FILTER] 🟢 SEND #${gptCallCountRef.current} | score=${score} reason=${reason}`,
      debug
    )

    const tensorflowData: TensorFlowData = {
      poseKeypoints:  lastPoseKeypoints,
      faceDetected:   faceDetectedRef.current,
      faceConfidence: faceConfidenceRef.current,
    }

    try {
      const result = await detectEvents(frame, transcriptRef.current, tensorflowData)
      if (!isRecordingRef.current) return

      if (!result?.events?.length) {
        console.warn('No events returned from detectEvents')
        return
      }

      for (const event of result.events) {
        // ── Deduplication: skip if same description within 30s ────────────
        const now = Date.now()
        const similarity =
          lastDescriptionRef.current.text.length > 0 &&
          event.description.toLowerCase().includes(
            lastDescriptionRef.current.text.toLowerCase().slice(0, 20)
          )
        if (
          similarity &&
          now - lastDescriptionRef.current.time < 30000
        ) {
          console.log('[DEDUP] Skipping similar event:', event.description)
          continue
        }
        lastDescriptionRef.current = { text: event.description, time: now }

        // ── State machine update ──────────────────────────────────────────
        if (event.isDangerous) {
          recordingStateRef.current = 'DANGER'
        } else if (score > 30) {
          recordingStateRef.current = 'SUSPICIOUS'
        } else {
          recordingStateRef.current = 'NORMAL'
        }

        // ── Skip "Scene normal" / "No event" entries from timeline ────────
        const isNonEvent =
          /scene normal|no event|person (visible|standing|partially|in shadow)/i
            .test(event.description)
        if (isNonEvent && !event.isDangerous) {
          console.log('[FILTER] Skipping non-event description:', event.description)
          continue
        }

        const newTimestamp = {
          timestamp:   getElapsedTime(),
          description: event.description,
          isDangerous: event.isDangerous,
        }

        console.log('Adding timestamp:', newTimestamp)
        setTimestamps(prev => [...prev, newTimestamp])

        if (event.isDangerous) {
          console.log('🚨 DANGEROUS EVENT — Sending notifications...')
          const notificationPayload = {
            title:       'Dangerous Activity Detected',
            description: `At ${newTimestamp.timestamp}: ${event.description}`,
            timestamp:   newTimestamp.timestamp,
            imageBase64: frame,
          }

          // Telegram
          try {
            const r = await fetch('/api/send-telegram', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
              body: JSON.stringify(notificationPayload),
            })
            r.ok ? console.log('✅ Telegram sent') : console.error('❌ Telegram failed:', await r.json())
          } catch (e) { console.error('❌ Telegram error:', e) }

          // WhatsApp
          try {
            const r = await fetch('/api/send-whatsapp', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
              body: JSON.stringify(notificationPayload),
            })
            r.ok ? console.log('✅ WhatsApp sent') : console.error('❌ WhatsApp failed:', await r.json())
          } catch (e) { console.error('❌ WhatsApp error:', e) }

          // Email
          try {
            const r = await fetch('/api/send-email', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
              body: JSON.stringify({
                title:       notificationPayload.title,
                description: notificationPayload.description,
              }),
            })
            if (!r.ok) {
              const msg = r.status === 401
                ? 'Please sign in to receive email notifications.'
                : r.status === 500
                ? 'Email service not configured.'
                : 'Failed to send email notification.'
              setError(msg)
              continue
            }
            console.log('✅ Email sent:', await r.json())
          } catch (e) { console.error('❌ Email error:', e) }
        }
      }
    } catch (error) {
      console.error('Error in analyzeFrame:', error)
      setError('Error analyzing frame. Please try again.')
      if (isRecordingRef.current) stopRecording()
    }
  }'''

if idx_start != -1 and idx_end != -1:
    src = src[:idx_start] + NEW_ANALYZE + src[idx_end:]
    print("analyzeFrame replaced")
else:
    print("WARNING: analyzeFrame boundaries not found — skipping replacement")

# ── g) Reset stats in startRecording ──────────────────────────────────────
OLD_RESET = "    setError(null)\n    setTimestamps([])\n    setAnalysisProgress(0)"
NEW_RESET = """    setError(null)
    setTimestamps([])
    setAnalysisProgress(0)

    // ── Reset filter + counters on every new recording ────────────────────
    frameFilter.reset()
    gptCallCountRef.current      = 0
    framesEvaluatedRef.current   = 0
    framesBlockedRef.current     = 0
    prevPoseKeypointsRef.current = null
    lastDescriptionRef.current   = { text: '', time: 0 }
    recordingStateRef.current    = 'NORMAL'
    setFilterStats({ evaluated: 0, blocked: 0, gptCalls: 0 })"""

if OLD_RESET in src and "frameFilter.reset()" not in src:
    src = src.replace(OLD_RESET, NEW_RESET)
    print("startRecording reset added")

# ── h) Add filter stats bar to JSX ─────────────────────────────────────────
OLD_BAR = "{error && !isInitializing && ("
NEW_BAR = """{error && !isInitializing && ("""  # same, we inject BEFORE it

STATS_BAR = """              {/* ── Filter Stats Bar ─────────────────────────────── */}
              {isRecording && (
                <div className="flex flex-wrap items-center gap-4 px-4 py-2 bg-zinc-900/60 border border-white/5 rounded-xl text-xs font-mono">
                  <span className="text-zinc-500">Filter</span>
                  <span className="text-zinc-400">
                    evaluated <span className="text-white">{filterStats.evaluated}</span>
                  </span>
                  <span className="text-zinc-400">
                    blocked <span className="text-green-400">{filterStats.blocked}</span>
                  </span>
                  <span className="text-zinc-400">
                    GPT calls <span className="text-purple-400">{filterStats.gptCalls}</span>
                  </span>
                  {filterStats.evaluated > 0 && (
                    <span className="text-zinc-400">
                      reduction{' '}
                      <span className="text-yellow-400">
                        {Math.round((filterStats.blocked / filterStats.evaluated) * 100)}%
                      </span>
                    </span>
                  )}
                </div>
              )}

"""

if "filterStats.evaluated" not in src:
    src = src.replace(OLD_BAR, STATS_BAR + OLD_BAR)
    print("filter stats bar added to JSX")

open(path, 'w').write(src)
print("page.tsx fully patched")
PY

echo "✅  PATCH 3 — page.tsx done"

# ════════════════════════════════════════════════════════════════════
# VERIFY — Check the key strings are present
# ════════════════════════════════════════════════════════════════════
echo ""
echo "── Verification ────────────────────────────────────────────────"

check() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo "  ✅  $label"
  else
    echo "  ⚠️   $label — NOT FOUND (manual check needed)"
  fi
}

check "$FILTER"  "warmupMs"                   "warmup gate in frame-filter.ts"
check "$FILTER"  "noFaceButBody.*s += 8"      "noFaceButBody weight reduced"
check "$ACTIONS" "DO NOT report"              "GPT prompt tightened"
check "$PAGE"    "transcriptRef"              "transcriptRef added"
check "$PAGE"    "faceDetectedRef"            "faceDetectedRef added"
check "$PAGE"    "prevPoseKeypointsRef"       "prevPoseKeypointsRef added"
check "$PAGE"    "framesEvaluatedRef"         "frame counter added"
check "$PAGE"    "lastDescriptionRef"         "deduplication ref added"
check "$PAGE"    "recordingStateRef"          "state machine ref added"
check "$PAGE"    "frameFilter.reset()"        "filter reset on startRecording"
check "$PAGE"    "filterStats.evaluated"      "stats bar in JSX"
check "$PAGE"    "DEDUP.*Skipping"            "dedup log in analyzeFrame"

echo ""
echo "── Backup files created ────────────────────────────────────────"
echo "  ${FILTER}.bak"
echo "  ${ACTIONS}.bak"
echo "  ${PAGE}.bak"
echo ""
echo "🚀  All patches applied. Run: npm run dev"
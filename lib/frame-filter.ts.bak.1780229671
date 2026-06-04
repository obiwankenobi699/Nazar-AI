// lib/frame-filter.ts
// Nazar AI — Smart Frame Filter
//
// Sits between TensorFlow and GPT in page.tsx.
// 3 layers: adaptive motion diff → anomaly score → cooldown gate
// Expected result: ~90% of frames never reach GPT.

// ─── Config ─────────────────────────────────────────────────────────────────

export interface FilterConfig {
  motionThreshold: number       // min fraction of pixels that must change (0–1)
  motionBaselineFrames: number  // frames to build per-camera "normal" baseline
  anomalyThreshold: number      // 0–100, GPT fires only above this
  cooldownMs: number            // minimum ms between two GPT calls
  fallFramesRequired: number    // consecutive "body low" frames before scoring as fall
  warmupMs: number              // ms after reset before GPT is allowed (avoids startup noise)
}

export const DEFAULT_CONFIG: FilterConfig = {
  motionThreshold: 0.06,
  motionBaselineFrames: 30,
  anomalyThreshold: 50,
  cooldownMs: 8000,
  fallFramesRequired: 3,
  warmupMs: 5000,
}

// ─── Input shape — matches what page.tsx already computes ───────────────────

export interface FilterHints {
  poseKeypoints: Array<{ x: number; y: number; score?: number; name?: string }>
  prevPoseKeypoints: Array<{ x: number; y: number; score?: number; name?: string }> | null
  faceDetected: boolean
  faceConfidence?: number
  transcript: string
  frameHeight: number
}

// ─── Output ─────────────────────────────────────────────────────────────────

export interface FilterResult {
  send: boolean
  score: number
  reason: 'first_frame' | 'no_motion' | 'low_score' | 'cooldown' | 'send'
  debug: {
    motionLevel: number
    adaptiveBaseline: number
    relativeMotion: number
    poseVelocity: number
    bodyLowStreak: number
    likelyFall: boolean
    suddenMovement: boolean
    noFaceButBody: boolean
    audioKeyword: boolean
    score: number
  }
}

// ─── FrameFilter class — one instance per camera ────────────────────────────

export class FrameFilter {
  private cfg: FilterConfig
  private lastImageData: ImageData | null = null
  private lastGptCall = 0

  // adaptive motion baseline
  private motionHistory: number[] = []
  private adaptiveMean = 0

  // temporal fall detection
  private bodyLowStreak = 0

  // sudden movement detection
  private velocityHistory: number[] = []

  // warmup tracking
  private startTime = Date.now()

  constructor(config: Partial<FilterConfig> = {}) {
    this.cfg = { ...DEFAULT_CONFIG, ...config }
  }

  // ── Main method ─────────────────────────────────────────────────────────

  evaluate(canvas: HTMLCanvasElement, hints: FilterHints): FilterResult {
    const ctx = canvas.getContext('2d')
    if (!ctx) {
      return this.result(false, 0, 'no_motion', this.emptyDebug())
    }

    const frame = ctx.getImageData(0, 0, canvas.width, canvas.height)

    // ── Warmup gate ──────────────────────────────────────────────────
    if (Date.now() - this.startTime < this.cfg.warmupMs) {
      this.lastImageData = frame
      this.updateBaseline(0)
      return this.result(false, 0, 'no_motion', this.emptyDebug())
    }

    // ── Layer 1: adaptive motion ─────────────────────────────────────────
    if (!this.lastImageData) {
      this.lastImageData = frame
      return this.result(false, 0, 'first_frame', this.emptyDebug())
    }

    const motionLevel = this.computeMotion(this.lastImageData.data, frame.data)
    this.updateBaseline(motionLevel)

    // relative motion: is this frame more active than normal for this camera?
    const relativeMotion = this.adaptiveMean > 0.001
      ? motionLevel / this.adaptiveMean
      : motionLevel / this.cfg.motionThreshold

    if (motionLevel < this.cfg.motionThreshold) {
      this.lastImageData = frame

      return this.result(false, 0, 'no_motion', {
        motionLevel, adaptiveBaseline: this.adaptiveMean,
        relativeMotion, poseVelocity: 0, bodyLowStreak: 0,
        likelyFall: false, suddenMovement: false,
        noFaceButBody: false, audioKeyword: false, score: 0
      })
    }

    // ── Layer 2: anomaly score ───────────────────────────────────────────
    const poseVelocity = this.computeVelocity(
      hints.prevPoseKeypoints,
      hints.poseKeypoints
    )
    this.velocityHistory.push(poseVelocity)
    if (this.velocityHistory.length > 10) this.velocityHistory.shift()

    const suddenMovement = this.detectSuddenMovement(poseVelocity)

    const bodyLow = this.isBodyLow(hints.poseKeypoints, hints.frameHeight)
    if (bodyLow) this.bodyLowStreak++
    else this.bodyLowStreak = 0

    const likelyFall = this.bodyLowStreak >= this.cfg.fallFramesRequired

    // body present but face not visible
    const noFaceButBody = !hints.faceDetected &&
      hints.poseKeypoints.filter(k => (k.score ?? 0) > 0.3).length >= 4

    const audioKeyword = this.hasAudioKeyword(hints.transcript)

    const score = this.computeScore({
      relativeMotion, suddenMovement, likelyFall, bodyLow,
      noFaceButBody, audioKeyword, poseVelocity,
      poseCount: hints.poseKeypoints.filter(k => (k.score ?? 0) > 0.3).length,
    })

    const debug = {
      motionLevel: Math.round(motionLevel * 1000) / 1000,
      adaptiveBaseline: Math.round(this.adaptiveMean * 1000) / 1000,
      relativeMotion: Math.round(relativeMotion * 100) / 100,
      poseVelocity: Math.round(poseVelocity * 1000) / 1000,
      bodyLowStreak: this.bodyLowStreak,
      likelyFall, suddenMovement, noFaceButBody, audioKeyword, score,
    }

    if (score < this.cfg.anomalyThreshold) {
      this.lastImageData = frame

      return this.result(false, score, 'low_score', debug)
    }


    // Emergency situations bypass cooldown
    const emergency =
      likelyFall ||
      audioKeyword ||
      score >= 85

    if (emergency) {
      this.lastImageData = frame
      this.lastGptCall = Date.now()

      return this.result(
        true,
        score,
        'send',
        debug
      )
    }

    // ── Layer 3: cooldown ────────────────────────────────────────────────
    if (Date.now() - this.lastGptCall < this.cfg.cooldownMs) {
      this.lastImageData = frame

      return this.result(false, score, 'cooldown', debug)
    }

    // ── All layers passed — GPT call is justified ────────────────────────
    this.lastImageData = frame
    this.lastGptCall = Date.now()
    return this.result(true, score, 'send', debug)
  }

  reset() {
    this.lastImageData = null
    this.lastGptCall = 0
    this.motionHistory = []
    this.adaptiveMean = 0
    this.bodyLowStreak = 0
    this.velocityHistory = []
    this.startTime = Date.now()
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  private computeMotion(a: Uint8ClampedArray, b: Uint8ClampedArray): number {
    let diff = 0
    const total = Math.floor(b.length / 16)
    for (let i = 0; i < b.length; i += 16) {
      if (Math.abs(a[i] - b[i]) + Math.abs(a[i+1] - b[i+1]) + Math.abs(a[i+2] - b[i+2]) > 30) {
        diff++
      }
    }
    return diff / total
  }

  private updateBaseline(v: number) {
    this.motionHistory.push(v)
    if (this.motionHistory.length > this.cfg.motionBaselineFrames) this.motionHistory.shift()
    this.adaptiveMean = this.motionHistory.reduce((a, b) => a + b, 0) / this.motionHistory.length
  }

  private computeVelocity(
    prev: Array<{ x: number; y: number; score?: number }> | null,
    curr: Array<{ x: number; y: number; score?: number }>
  ): number {
    if (!prev || prev.length !== curr.length) return 0
    let total = 0, count = 0
    for (let i = 0; i < curr.length; i++) {
      if ((curr[i].score ?? 0) > 0.3 && (prev[i].score ?? 0) > 0.3) {
        const dx = curr[i].x - prev[i].x
        const dy = curr[i].y - prev[i].y
        total += Math.sqrt(dx * dx + dy * dy)
        count++
      }
    }
    return count === 0 ? 0 : Math.min(total / count / 50, 1)
  }

  private detectSuddenMovement(current: number): boolean {
    if (this.velocityHistory.length < 5) return false
    const avg = this.velocityHistory.reduce((a, b) => a + b, 0) / this.velocityHistory.length
    return current > avg * 2.5 && current > 0.25
  }

  private isBodyLow(
    keypoints: Array<{ x: number; y: number; score?: number }>,
    frameHeight: number
  ): boolean {
    const relevant = [0, 11, 12]
      .map(i => keypoints[i])
      .filter(k => k && (k.score ?? 0) > 0.3)
    if (relevant.length < 2) return false
    return relevant.every(k => k.y / frameHeight > 0.6)
  }

  private hasAudioKeyword(transcript: string): boolean {
    if (!transcript) return false
    const keywords = ['help', 'fire', 'stop', 'thief', 'fight', 'police', 'no', 'aah', 'attack', 'gun']
    return keywords.some(k => transcript.toLowerCase().includes(k))
  }

  private computeScore(f: {
    relativeMotion: number; suddenMovement: boolean; likelyFall: boolean
    bodyLow: boolean; noFaceButBody: boolean; audioKeyword: boolean
    poseVelocity: number; poseCount: number
  }): number {
    let s = 0
    s += Math.min(f.relativeMotion * 12, 30)  // above-normal motion for this camera
    if (f.suddenMovement) s += 25              // velocity spike — lunge, fight
    if (f.likelyFall)     s += 30             // confirmed fall (N frames)
    else if (f.bodyLow)   s += 10             // partial fall signal
    if (f.noFaceButBody)  s += 8              // person down / turned away (reduced: dark room FP)
    if (f.audioKeyword)   s += 30             // shouting keywords
    if (f.poseCount < 5 && f.poseCount > 0) s += 10  // person obscured
    return Math.min(Math.round(s), 100)
  }

  private result(
    send: boolean, score: number,
    reason: FilterResult['reason'], debug: FilterResult['debug']
  ): FilterResult {
    return { send, score, reason, debug }
  }

  private emptyDebug(): FilterResult['debug'] {
    return {
      motionLevel: 0, adaptiveBaseline: 0, relativeMotion: 0, poseVelocity: 0,
      bodyLowStreak: 0, likelyFall: false, suddenMovement: false,
      noFaceButBody: false, audioKeyword: false, score: 0
    }
  }
}

// Singleton — one filter for the single webcam session
export const frameFilter = new FrameFilter()
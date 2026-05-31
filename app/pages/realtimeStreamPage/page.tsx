"use client"
import { frameFilter } from '@/lib/frame-filter'
import type React from "react"
import { useState, useRef, useEffect } from "react"
import { Camera, StopCircle, PlayCircle, Save, Loader2 } from "lucide-react"
import { Progress } from "@/components/ui/progress"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import TimestampList from "@/components/timestamp-list"
import ChatInterface from "@/components/chat-interface"
import { Timeline } from "../../components/Timeline"
import type { Timestamp } from "@/app/types"
import { detectEvents, type VideoEvent, type TensorFlowData } from "./actions"

// Dynamically import TensorFlow.js and models
import { loadTensorFlowModules, isTensorFlowReady, type TensorFlowModules } from '@/lib/tensorflow-loader'
import type * as blazeface from '@tensorflow-models/blazeface'
import type * as posedetection from '@tensorflow-models/pose-detection'
import type * as tf from '@tensorflow/tfjs'

let tfModules: TensorFlowModules | null = null

interface SavedVideo {
  id: string
  name: string
  url: string
  thumbnailUrl: string
  timestamps: Timestamp[]
}

interface Keypoint {
  x: number
  y: number
  score?: number
  name?: string
}

interface FacePrediction {
  topLeft: [number, number] | tf.Tensor1D
  bottomRight: [number, number] | tf.Tensor1D
  landmarks?: Array<[number, number]> | tf.Tensor2D
  probability: number | tf.Tensor1D
}

export default function Page() {
  // States
  const [isRecording, setIsRecording] = useState(false)
  const [timestamps, setTimestamps] = useState<Timestamp[]>([])
  const [analysisProgress, setAnalysisProgress] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [isInitializing, setIsInitializing] = useState(true)
  const [currentTime, setCurrentTime] = useState(0)
  const [videoDuration, setVideoDuration] = useState(0)
  const [initializationProgress, setInitializationProgress] = useState<string>('')
  const [transcript, setTranscript] = useState('')
  const [isTranscribing, setIsTranscribing] = useState(false)
  const [videoName, setVideoName] = useState('')
  const [recordedVideoUrl, setRecordedVideoUrl] = useState<string | null>(null)
  const [mlModelsReady, setMlModelsReady] = useState(false)
  const [lastPoseKeypoints, setLastPoseKeypoints] = useState<Keypoint[]>([])
  const [isClient, setIsClient] = useState(false)
  const [filterStats, setFilterStats] = useState({ evaluated: 0, blocked: 0, gptCalls: 0 })

  // Refs
  const videoRef = useRef<HTMLVideoElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const mediaStreamRef = useRef<MediaStream | null>(null)
  const analysisIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const detectionFrameRef = useRef<number | null>(null)
  const lastDetectionTime = useRef<number>(0)
  const lastFrameTimeRef = useRef<number>(performance.now())
  const startTimeRef = useRef<Date | null>(null)
  const faceModelRef = useRef<blazeface.BlazeFaceModel | null>(null)
  const poseModelRef = useRef<posedetection.PoseDetector | null>(null)
  const recognitionRef = useRef<SpeechRecognition | null>(null)
  const mediaRecorderRef = useRef<MediaRecorder | null>(null)
  const recordedChunksRef = useRef<Blob[]>([])
  const isRecordingRef = useRef<boolean>(false)
  const durationIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null)

  // ── Fresh refs — no stale closures ──────────────────────────────────────
  const transcriptRef        = useRef<string>('')
  const faceDetectedRef      = useRef<boolean>(false)
  const faceConfidenceRef    = useRef<number | undefined>(undefined)
  const prevPoseKeypointsRef = useRef<Keypoint[] | null>(null)
  const lastDescriptionRef   = useRef<{ text: string; time: number }>({ text: '', time: 0 })
  const recordingStateRef    = useRef<'NORMAL' | 'SUSPICIOUS' | 'DANGER'>('NORMAL')
  const gptCallCountRef      = useRef(0)
  const framesEvaluatedRef   = useRef(0)
  const framesBlockedRef     = useRef(0)
  // -----------------------------
  // 1) Initialize ML Models
  // -----------------------------
  const initMLModels = async () => {
    // Only run on client side
    if (typeof window === 'undefined') {
      return
    }
    
    try {
      setIsInitializing(true)
      setMlModelsReady(false)
      setError(null)

      setInitializationProgress('Loading TensorFlow.js modules...')
      
      // Load TensorFlow modules using the utility
      tfModules = await loadTensorFlowModules()
      
      if (!tfModules) {
        throw new Error('Failed to load TensorFlow.js modules')
      }

      // Load models in parallel
      setInitializationProgress('Initializing AI models...')
      const [faceModel, poseModel] = await Promise.all([
        tfModules.blazefaceModel.load({
          maxFaces: 1, // Limit to 1 face for better performance
          scoreThreshold: 0.5 // Increase threshold for better performance
        }),
        tfModules.poseDetection.createDetector(
          tfModules.poseDetection.SupportedModels.MoveNet,
          {
            modelType: tfModules.poseDetection.movenet.modelType.SINGLEPOSE_LIGHTNING,
            enableSmoothing: true,
            minPoseScore: 0.3
          }
        )
      ])

      faceModelRef.current = faceModel
      poseModelRef.current = poseModel

      setMlModelsReady(true)
      setIsInitializing(false)
      console.log('All ML models loaded successfully')
    } catch (err) {
      console.error('Error loading ML models:', err)
      setError('Failed to load ML models: ' + (err as Error).message)
      setMlModelsReady(false)
      setIsInitializing(false)
    }
  }

  // Helper to set canvas dimensions
  const updateCanvasSize = () => {
    if (!videoRef.current || !canvasRef.current) return
    const canvas = canvasRef.current
    canvas.width = 640 // fixed width
    canvas.height = 360 // fixed height (16:9)
  }

  // -----------------------------
  // 2) Set up the webcam
  // -----------------------------
  const startWebcam = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: {
          width: { ideal: 640, max: 640 },
          height: { ideal: 360, max: 360 },
          frameRate: { ideal: 30 },
          facingMode: "user"
        },
        audio: true
      })
      if (videoRef.current) {
        videoRef.current.srcObject = stream
        mediaStreamRef.current = stream

        // Wait for video metadata so we can set the canvas size
        await new Promise<void>((resolve) => {
          videoRef.current!.onloadedmetadata = () => {
            updateCanvasSize()
            resolve()
          }
        })
      }
    } catch (error) {
      console.error("Error accessing webcam:", error)
      setError(
        "Failed to access webcam. Please make sure you have granted camera permissions."
      )
    }
  }

  const stopWebcam = () => {
    if (mediaStreamRef.current) {
      mediaStreamRef.current.getTracks().forEach((track) => track.stop())
      mediaStreamRef.current = null
    }
    if (videoRef.current) {
      videoRef.current.srcObject = null
    }
    if (recordedVideoUrl) {
      URL.revokeObjectURL(recordedVideoUrl)
      setRecordedVideoUrl(null)
    }
  }

  // -----------------------------
  // 3) Speech Recognition
  // -----------------------------
  const initSpeechRecognition = () => {
    if (typeof window === "undefined") return
    if ("webkitSpeechRecognition" in window) {
      const SpeechRecognition = window.webkitSpeechRecognition
      const recognition = new SpeechRecognition()
      recognition.continuous = true
      recognition.interimResults = true

      recognition.onresult = (event: SpeechRecognitionEvent) => {
        let finalTranscript = ""
        for (let i = event.resultIndex; i < event.results.length; ++i) {
          if (event.results[i].isFinal) {
            finalTranscript += event.results[i][0].transcript
          }
        }
        if (finalTranscript) {
          setTranscript((prev) => prev + " " + finalTranscript)
        }
      }

      recognitionRef.current = recognition
    } else {
      console.warn("Speech recognition not supported in this browser.")
    }
  }

  // -----------------------------
  // 4) TensorFlow detection loop
  // -----------------------------
  const runDetection = async () => {
    if (!isRecordingRef.current) return

    // Check if ML models are ready before proceeding
    if (!mlModelsReady || !faceModelRef.current || !poseModelRef.current) {
      detectionFrameRef.current = requestAnimationFrame(runDetection)
      return
    }

    // Throttle detection to ~10 FPS (every 100ms)
    const now = performance.now()
    if (now - lastDetectionTime.current < 100) {
      detectionFrameRef.current = requestAnimationFrame(runDetection)
      return
    }
    lastDetectionTime.current = now

    const video = videoRef.current
    const canvas = canvasRef.current
    if (!video || !canvas) {
      detectionFrameRef.current = requestAnimationFrame(runDetection)
      return
    }

    const ctx = canvas.getContext("2d")
    if (!ctx) {
      detectionFrameRef.current = requestAnimationFrame(runDetection)
      return
    }

    // Clear canvas and draw current video frame
    ctx.clearRect(0, 0, canvas.width, canvas.height)
    drawVideoToCanvas(video, canvas, ctx)

    // Scale for drawing predictions
    const scaleX = canvas.width / video.videoWidth
    const scaleY = canvas.height / video.videoHeight

    // Face detection
    if (faceModelRef.current) {
      try {
        const predictions = await faceModelRef.current.estimateFaces(video, false)
        faceDetectedRef.current   = predictions.length > 0
        faceConfidenceRef.current = predictions.length > 0 ? predictions[0].probability as number : undefined
        predictions.forEach((prediction: blazeface.NormalizedFace) => {
          const start = prediction.topLeft as [number, number]
          const end = prediction.bottomRight as [number, number]
          const size = [end[0] - start[0], end[1] - start[1]]

          const scaledStart = [start[0] * scaleX, start[1] * scaleY]
          const scaledSize = [size[0] * scaleX, size[1] * scaleX]

          // Draw bounding box
          ctx.strokeStyle = "rgba(0, 255, 0, 0.8)"
          ctx.lineWidth = 2
          ctx.strokeRect(
            scaledStart[0],
            scaledStart[1],
            scaledSize[0],
            scaledSize[1]
          )

          // Draw confidence
          const confidence = Math.round((prediction.probability as number) * 100)
          ctx.fillStyle = "white"
          ctx.font = "16px Arial"
          ctx.fillText(`${confidence}%`, scaledStart[0], scaledStart[1] - 5)
        })
      } catch (err) {
        console.error("Face detection error:", err)
      }
    }

    // Pose detection
    if (poseModelRef.current) {
      try {
        const poses = await poseModelRef.current.estimatePoses(video)
        if (poses.length > 0) {
          const keypoints = poses[0].keypoints
          // Convert TF keypoints to our Keypoint type
          const convertedKeypoints: Keypoint[] = keypoints.map(kp => ({
            x: kp.x,
            y: kp.y,
            score: kp.score ?? 0, // Use 0 as default if score is undefined
            name: kp.name
          }))
          prevPoseKeypointsRef.current = lastPoseKeypoints

   setLastPoseKeypoints(convertedKeypoints)

          keypoints.forEach((keypoint) => {
            // Use nullish coalescing to provide a default value of 0
            if ((keypoint.score ?? 0) > 0.3) {
              const x = keypoint.x * scaleX
              const y = keypoint.y * scaleY

              // Draw keypoint
              ctx.beginPath()
              ctx.arc(x, y, 4, 0, 2 * Math.PI)
              ctx.fillStyle = "rgba(255, 0, 0, 0.8)"
              ctx.fill()

              // Outer circle
              ctx.beginPath()
              ctx.arc(x, y, 6, 0, 2 * Math.PI)
              ctx.strokeStyle = "white"
              ctx.lineWidth = 1.5
              ctx.stroke()

              // Label (if available)
              // Use nullish coalescing to provide a default value of 0
              if ((keypoint.score ?? 0) > 0.5 && keypoint.name) {
                ctx.fillStyle = "white"
                ctx.font = "12px Arial"
                ctx.fillText(`${keypoint.name}`, x + 8, y)
              }
            }
          })
        }
      } catch (err) {
        console.error("Pose detection error:", err)
      }
    }

    // (Optional) Compute FPS
    lastFrameTimeRef.current = performance.now()

    detectionFrameRef.current = requestAnimationFrame(runDetection)
  }

  // Helper: Draw video to canvas (maintaining aspect ratio)
  const drawVideoToCanvas = (
    video: HTMLVideoElement,
    canvas: HTMLCanvasElement,
    ctx: CanvasRenderingContext2D
  ) => {
    const videoAspect = video.videoWidth / video.videoHeight
    const canvasAspect = canvas.width / canvas.height

    let drawWidth = canvas.width
    let drawHeight = canvas.height
    let offsetX = 0
    let offsetY = 0

    if (videoAspect > canvasAspect) {
      drawHeight = canvas.width / videoAspect
      offsetY = (canvas.height - drawHeight) / 2
    } else {
      drawWidth = canvas.height * videoAspect
      offsetX = (canvas.width - drawWidth) / 2
    }

    ctx.drawImage(video, offsetX, offsetY, drawWidth, drawHeight)
  }

  // -----------------------------
  // 5) analyzeFrame — filter-first, then GPT
  // -----------------------------
  const analyzeFrame = async () => {
    if (!isRecordingRef.current) return
    if (!canvasRef.current) return

    framesEvaluatedRef.current++

    const hints = {
      poseKeypoints:     lastPoseKeypoints,
      prevPoseKeypoints: prevPoseKeypointsRef.current,
      faceDetected:      faceDetectedRef.current,
      faceConfidence:    faceConfidenceRef.current,
      transcript:        transcriptRef.current,
      frameHeight:       canvasRef.current.height,
    }

    const { send, score, reason, debug } = frameFilter.evaluate(canvasRef.current, hints)

    if (!send) {
      framesBlockedRef.current++
      if (framesEvaluatedRef.current % 10 === 0) {
        setFilterStats({
          evaluated: framesEvaluatedRef.current,
          blocked:   framesBlockedRef.current,
          gptCalls:  gptCallCountRef.current,
        })
      }
      console.log(`[FILTER] ⚪ DROP reason=${reason} score=${score}`)
      return
    }

    const frame = await captureFrame()
    if (!frame || !frame.startsWith('data:image/jpeg')) return

    gptCallCountRef.current++
    setFilterStats({
      evaluated: framesEvaluatedRef.current,
      blocked:   framesBlockedRef.current,
      gptCalls:  gptCallCountRef.current,
    })
    console.log(`[FILTER] 🟢 SEND #${gptCallCountRef.current} score=${score}`, debug)

    const tensorflowData: TensorFlowData = {
      poseKeypoints:  lastPoseKeypoints,
      faceDetected:   faceDetectedRef.current,
      faceConfidence: faceConfidenceRef.current,
    }

    try {
      const result = await detectEvents(frame, transcriptRef.current, tensorflowData)
      if (!isRecordingRef.current) return
      if (!result?.events?.length) return

      for (const event of result.events) {
        // Dedup: skip if same description within 30s
        const now = Date.now()
        const isSimilar =
          lastDescriptionRef.current.text.length > 10 &&
          now - lastDescriptionRef.current.time < 30000 &&
          event.description.toLowerCase().includes(
            lastDescriptionRef.current.text.toLowerCase().slice(0, 20)
          )
        if (isSimilar) { console.log('[DEDUP] skipped:', event.description); continue }
        lastDescriptionRef.current = { text: event.description, time: now }

        // State machine
        recordingStateRef.current = event.isDangerous ? 'DANGER' : score > 30 ? 'SUSPICIOUS' : 'NORMAL'

        // Skip non-events
        if (/scene normal|no event|person (visible|standing|partially|in shadow)/i.test(event.description) && !event.isDangerous) {
          console.log('[FILTER] non-event skipped:', event.description)
          continue
        }

        const newTimestamp = {
          timestamp:   getElapsedTime(),
          description: event.description,
          isDangerous: event.isDangerous,
        }
        setTimestamps(prev => [...prev, newTimestamp])

        if (event.isDangerous) {
          const payload = {
            title:       'Dangerous Activity Detected',
            description: `At ${newTimestamp.timestamp}: ${event.description}`,
            timestamp:   newTimestamp.timestamp,
            imageBase64: frame,
          }
          try {
            const r = await fetch('/api/send-telegram', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(payload) })
            r.ok ? console.log('✅ Telegram') : console.error('❌ Telegram', await r.json())
          } catch(e) { console.error('❌ Telegram', e) }
          try {
            const r = await fetch('/api/send-whatsapp', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(payload) })
            r.ok ? console.log('✅ WhatsApp') : console.error('❌ WhatsApp', await r.json())
          } catch(e) { console.error('❌ WhatsApp', e) }
          try {
            const r = await fetch('/api/send-email', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ title: payload.title, description: payload.description }) })
            if (!r.ok) { setError(r.status===401?'Sign in for email alerts.':'Email service error.'); continue }
            console.log('✅ Email', await r.json())
          } catch(e) { console.error('❌ Email', e) }
        }
      }
    } catch (err) {
      console.error('analyzeFrame error:', err)
      setError('Error analyzing frame.')
      if (isRecordingRef.current) stopRecording()
    }
  }
  // -----------------------------
  // 6) Capture current video frame (for analysis)
  // -----------------------------
  const captureFrame = async (): Promise<string | null> => {
    if (!videoRef.current) return null

    const video = videoRef.current
    const tempCanvas = document.createElement("canvas")
    const width = 640
    const height = 360
    tempCanvas.width = width
    tempCanvas.height = height

    const context = tempCanvas.getContext("2d")
    if (!context) return null

    try {
      context.drawImage(video, 0, 0, width, height)
      const dataUrl = tempCanvas.toDataURL("image/jpeg", 0.8)
      return dataUrl
    } catch (error) {
      console.error("Error capturing frame:", error)
      return null
    }
  }

  // -----------------------------
  // 7) Get elapsed time string
  // -----------------------------
  const getElapsedTime = () => {
    if (!startTimeRef.current) return "00:00"
    const elapsed = Math.floor(
      (Date.now() - startTimeRef.current.getTime()) / 1000
    )
    // Update current time for timeline
    setCurrentTime(elapsed)
    const minutes = Math.floor(elapsed / 60)
    const seconds = elapsed % 60
    return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
  }

  // -----------------------------
  // 8) Recording control (start/stop)
  // -----------------------------
  const startRecording = async () => {
    setCurrentTime(0)
    setVideoDuration(0)
    
    // Load TensorFlow models on demand when starting recording
    if (!mlModelsReady) {
      console.log("📦 Loading TensorFlow models on demand...")
      setInitializationProgress("Loading AI models...")
      setIsInitializing(true)
      try {
        await initMLModels()
      } catch (err) {
        setError("Failed to load ML models: " + (err as Error).message)
        setIsInitializing(false)
        return
      }
    }
    
    if (!mediaStreamRef.current) {
      setError("Camera not ready. Please wait.")
      return
    }

    setError(null)
    setTimestamps([])
    setAnalysisProgress(0)
    frameFilter.reset()
    gptCallCountRef.current    = 0
    framesEvaluatedRef.current = 0
    framesBlockedRef.current   = 0
    prevPoseKeypointsRef.current = null
    lastDescriptionRef.current   = { text: '', time: 0 }
    recordingStateRef.current    = 'NORMAL'
    setFilterStats({ evaluated: 0, blocked: 0, gptCalls: 0 })

    startTimeRef.current = new Date()
    isRecordingRef.current = true
    setIsRecording(true)
    // Start tracking video duration
    if (durationIntervalRef.current) {
      clearInterval(durationIntervalRef.current)
    }
    durationIntervalRef.current = setInterval(() => {
      if (isRecordingRef.current) {
        const elapsed = Math.floor((Date.now() - startTimeRef.current!.getTime()) / 1000)
        setVideoDuration(elapsed)
      }
    }, 1000)

    // Start speech recognition
    if (recognitionRef.current) {
      setTranscript("")
      setIsTranscribing(true)
      recognitionRef.current.start()
    }

    // Start video recording using MediaRecorder with WebM container (MP4 not supported by browsers)
    recordedChunksRef.current = []
    
    // Check for supported mimeType with audio+video codecs
    const getSupportedMimeType = () => {
      const types = [
        'video/webm;codecs=vp9,opus',
        'video/webm;codecs=vp8,opus', 
        'video/webm;codecs=vp9',
        'video/webm;codecs=vp8',
        'video/webm'
      ]
      for (const type of types) {
        if (MediaRecorder.isTypeSupported(type)) {
          return type
        }
      }
      return 'video/webm'
    }
    
    const mimeType = getSupportedMimeType()
    console.log('Using MediaRecorder mimeType:', mimeType)
    
    const mediaRecorder = new MediaRecorder(mediaStreamRef.current, {
      mimeType
    })

    mediaRecorder.ondataavailable = (event) => {
      if (event.data.size > 0) {
        recordedChunksRef.current.push(event.data)
      }
    }

    mediaRecorder.onstop = () => {
      const blob = new Blob(recordedChunksRef.current, { type: mimeType })
      const url = URL.createObjectURL(blob)
      setRecordedVideoUrl(url)
      setVideoName("stream.webm")
    }

    // Set up data handling before starting
    mediaRecorder.ondataavailable = (event) => {
      if (event.data && event.data.size > 0) {
        recordedChunksRef.current.push(event.data)
      }
    }

    mediaRecorder.onstop = () => {
      const blob = new Blob(recordedChunksRef.current, { type: mimeType })
      const url = URL.createObjectURL(blob)
      setRecordedVideoUrl(url)
      setVideoName("stream.webm")
    }

    mediaRecorderRef.current = mediaRecorder
    // Start recording with a timeslice of 1000ms (1 second)
    mediaRecorder.start(1000)

    // Start the TensorFlow detection loop only if models are ready
    if (detectionFrameRef.current) {
      cancelAnimationFrame(detectionFrameRef.current)
    }
    
    // Only start detection if ML models are loaded
    if (mlModelsReady) {
      lastDetectionTime.current = 0
      detectionFrameRef.current = requestAnimationFrame(runDetection)
    } else {
      console.warn("ML models not ready yet, detection will start once loaded")
    }

    // Set up repeated frame analysis every 3 seconds
    if (analysisIntervalRef.current) {
      clearInterval(analysisIntervalRef.current)
    }
    analyzeFrame() // first immediate call
    analysisIntervalRef.current = setInterval(analyzeFrame, 3000)
  }

  const stopRecording = () => {
    startTimeRef.current = null
    isRecordingRef.current = false
    setIsRecording(false)

    if (recognitionRef.current) {
      recognitionRef.current.stop()
      setIsTranscribing(false)
    }

    // Stop MediaRecorder if active
    if (mediaRecorderRef.current && mediaRecorderRef.current.state !== "inactive") {
      mediaRecorderRef.current.stop()
    }

    // Stop detection loop and analysis interval
    if (detectionFrameRef.current) {
      cancelAnimationFrame(detectionFrameRef.current)
      detectionFrameRef.current = null
    }
    if (analysisIntervalRef.current) {
      clearInterval(analysisIntervalRef.current)
      analysisIntervalRef.current = null
    }
    if (durationIntervalRef.current) {
      clearInterval(durationIntervalRef.current)
      durationIntervalRef.current = null
    }
  }

  // -----------------------------
  // 9) Save video functionality
  // -----------------------------
  const handleSaveVideo = () => {
    if (!recordedVideoUrl || !videoName) return

    try {
      const savedVideos: SavedVideo[] = JSON.parse(
        localStorage.getItem("savedVideos") || "[]"
      )
      const newVideo: SavedVideo = {
        id: Date.now().toString(),
        name: videoName,
        url: recordedVideoUrl,
        thumbnailUrl: recordedVideoUrl,
        timestamps: timestamps
      }
      savedVideos.push(newVideo)
      localStorage.setItem("savedVideos", JSON.stringify(savedVideos))
      alert("Video saved successfully!")
    } catch (error) {
      console.error("Error saving video:", error)
      alert("Failed to save video. Please try again.")
    }
  }

  // -----------------------------
  // 10) useEffect hooks
  // -----------------------------
  useEffect(() => {
    setIsClient(true)
  }, [])

  useEffect(() => { transcriptRef.current = transcript }, [transcript])

  // Update current time and duration
  useEffect(() => {
    const video = videoRef.current
    if (!video) return

    const handleTimeUpdate = () => {
      setCurrentTime(video.currentTime)
    }

    const handleLoadedMetadata = () => {
      setVideoDuration(video.duration || 60)
      // Reset playback position to start
      video.currentTime = 0
    }

    video.addEventListener('timeupdate', handleTimeUpdate)
    video.addEventListener('loadedmetadata', handleLoadedMetadata)

    // Reset playback position when video source changes
    video.currentTime = 0

    return () => {
      video.removeEventListener('timeupdate', handleTimeUpdate)
      video.removeEventListener('loadedmetadata', handleLoadedMetadata)
    }
  }, [recordedVideoUrl])

  useEffect(() => {
    // Only initialize on client side
    if (typeof window === 'undefined') return
    
    initSpeechRecognition()
    const init = async () => {
      await startWebcam()
      // TensorFlow models are now loaded on-demand when Start Recording is clicked
      // This makes the page load faster
      console.log("📷 Webcam ready. TensorFlow will load when you click Start Recording.")
      setIsInitializing(false)
    }
    init()

    return () => {
      stopWebcam()
      if (analysisIntervalRef.current) clearInterval(analysisIntervalRef.current)
      if (detectionFrameRef.current) cancelAnimationFrame(detectionFrameRef.current)
    }
  }, [isClient]) // Only run after client-side hydration

  // Start detection when ML models become ready and recording is active
  useEffect(() => {
    if (mlModelsReady && isRecordingRef.current && !detectionFrameRef.current) {
      console.log("Starting TensorFlow detection now that models are ready")
      lastDetectionTime.current = 0
      detectionFrameRef.current = requestAnimationFrame(runDetection)
    }
  }, [mlModelsReady])

  // -----------------------------
  // Render
  // -----------------------------
  // Don't render anything on server-side
  if (!isClient) {
    return (
      <div className="min-h-screen bg-black text-white flex items-center justify-center p-4">
        <div className="flex flex-col items-center gap-4">
          <Loader2 className="w-8 h-8 animate-spin text-purple-500" />
          <p className="text-zinc-300">Loading application...</p>
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-screen bg-black text-white flex flex-col items-center justify-start py-8 px-4 sm:px-6">
      <div className="w-full max-w-5xl relative">
        <div className="absolute inset-0 bg-purple-900/5 blur-3xl rounded-full"></div>
        <div className="relative z-10 p-0 sm:p-8">
          <div className="space-y-6 sm:space-y-8">
            <div className="text-center px-4">
              <h1 className="text-2xl sm:text-3xl font-bold mb-2 text-white drop-shadow-[0_0_10px_rgba(255,255,255,0.7)]">
                Real-time Stream Analyzer
              </h1>
              <p className="text-zinc-400 text-sm sm:text-base">
                Analyze your live stream in real-time and detect key moments
              </p>
            </div>

            <div className="space-y-4">
              <div className="relative aspect-video rounded-xl overflow-hidden bg-zinc-900 border border-white/10 shadow-2xl">
                {isInitializing && (
                  <div className="absolute inset-0 flex flex-col items-center justify-center bg-zinc-900/90 z-20 p-4">
                    <Loader2 className="w-8 h-8 animate-spin text-purple-500 mb-2" />
                    <p className="text-zinc-300 text-center text-sm">{initializationProgress}</p>
                  </div>
                )}
                <div className="relative w-full h-full" style={{ aspectRatio: "16/9" }}>
                  {isClient && (
                    <video
                      ref={videoRef}
                      autoPlay
                      playsInline
                      muted
                      className="absolute inset-0 w-full h-full object-cover opacity-0"
                    />
                  )}
                  <canvas
                    ref={canvasRef}
                    className="absolute inset-0 w-full h-full object-cover"
                  />
                </div>
              </div>


                {/* Filter Stats Bar */}
                {isRecording && (
                  <div className="flex flex-wrap items-center gap-4 px-4 py-2 bg-zinc-900/60 border border-white/5 rounded-xl text-xs font-mono">
                    <span className="text-zinc-500">Filter</span>
                    <span className="text-zinc-400">evaluated <span className="text-white">{filterStats.evaluated}</span></span>
                    <span className="text-zinc-400">blocked <span className="text-green-400">{filterStats.blocked}</span></span>
                    <span className="text-zinc-400">GPT calls <span className="text-purple-400">{filterStats.gptCalls}</span></span>
                    {filterStats.evaluated > 0 && (
                      <span className="text-zinc-400">reduction <span className="text-yellow-400">{Math.round((filterStats.blocked / filterStats.evaluated) * 100)}%</span></span>
                    )}
                  </div>
                )}

              {error && !isInitializing && (
                <div className="p-4 bg-red-900/50 border border-red-500 rounded-lg text-red-200 text-sm">
                  {error}
                </div>
              )}

              <div className="flex flex-wrap justify-center gap-3 sm:gap-4 px-2">
                {isInitializing ? (
                  <Button
                    disabled
                    className="flex items-center gap-2 px-6 py-4 bg-zinc-600 rounded-xl transition-colors cursor-not-allowed text-sm sm:text-base"
                  >
                    <Loader2 className="w-5 h-5 animate-spin" />
                    Initializing...
                  </Button>
                ) : !isRecording ? (
                  <Button
                    onClick={startRecording}
                    className="flex items-center gap-2 px-6 py-4 bg-green-600 hover:bg-green-700 rounded-xl transition-all hover:scale-105 active:scale-95 text-sm sm:text-base font-semibold"
                  >
                    <PlayCircle className="w-5 h-5" />
                    Start Analysis
                  </Button>
                ) : (
                  <Button
                    onClick={stopRecording}
                    className="flex items-center gap-2 px-6 py-4 bg-red-600 hover:bg-red-700 rounded-xl transition-all hover:scale-105 active:scale-95 text-sm sm:text-base font-semibold"
                  >
                    <StopCircle className="w-5 h-5" />
                    Stop Analysis
                  </Button>
                )}
              </div>

              {isRecording && (
                <div className="flex justify-center">
                  <div className="flex items-center gap-2 px-3 py-1 bg-red-500/10 border border-red-500/20 rounded-full">
                    <div className="w-2 h-2 rounded-full bg-red-500 animate-pulse" />
                    <span className="text-xs font-medium text-red-400 uppercase tracking-wider">
                      Live Analysis
                    </span>
                  </div>
                </div>
              )}

              <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 mt-8">
                <div className="lg:col-span-2 space-y-6">
                  <div className="bg-zinc-900/30 p-4 sm:p-6 rounded-2xl border border-white/5 backdrop-blur-sm">
                    <h2 className="text-lg sm:text-xl font-semibold text-white mb-4">
                      Key Moments Timeline
                    </h2>
                    {timestamps.length > 0 ? (
                      <Timeline
                        events={timestamps.map(ts => {
                          const [m, s] = ts.timestamp.split(':').map(Number);
                          return {
                            startTime: m * 60 + s,
                            endTime: m * 60 + s + 3,
                            type: ts.isDangerous ? 'warning' : 'normal',
                            label: ts.description
                          };
                        })}
                        totalDuration={videoDuration || 60}
                        currentTime={currentTime}
                      />
                    ) : (
                      <p className="text-zinc-500 text-sm sm:text-base italic">
                        {isRecording ? "Detection active, waiting for events..." : "Start analysis to begin detection."}
                      </p>
                    )}
                  </div>

                  {/* Transcript Section */}
                  <div className="bg-zinc-900/30 p-4 sm:p-6 rounded-2xl border border-white/5 backdrop-blur-sm">
                    <div className="flex items-center justify-between mb-4">
                      <h2 className="text-lg sm:text-xl font-semibold text-white">
                        Audio Transcript
                      </h2>
                      {isTranscribing && (
                        <div className="flex items-center gap-2">
                          <div className="w-2 h-2 rounded-full bg-blue-500 animate-pulse" />
                          <span className="text-xs text-blue-400">Listening...</span>
                        </div>
                      )}
                    </div>
                    <div className="min-h-[100px] p-4 bg-black/40 rounded-xl border border-white/10">
                      {transcript ? (
                        <p className="text-zinc-300 text-sm sm:text-base leading-relaxed whitespace-pre-wrap">
                          {transcript}
                        </p>
                      ) : (
                        <p className="text-zinc-500 text-sm italic">
                          {isRecording ? "Waiting for speech activity..." : "No audio transcript available."}
                        </p>
                      )}
                    </div>
                  </div>
                </div>

                <div className="lg:col-span-1">
                  <div className="bg-zinc-900/30 p-4 rounded-2xl border border-white/5 h-full">
                    <h2 className="text-lg font-semibold text-white mb-4">Event Feed</h2>
                    <TimestampList
                      timestamps={timestamps}
                      onTimestampClick={() => {}}
                    />
                  </div>
                </div>
              </div>

              {/* Save section – shown only after recording stops */}
              {isClient && !isRecording && recordedVideoUrl && (
                <div className="mt-8 p-6 bg-zinc-900/10 rounded-2xl border border-white/5 backdrop-blur-sm">
                  <h2 className="text-xl font-semibold mb-4 text-white">
                    Save Recording
                  </h2>
                  <div className="flex gap-4">
                    <Input
                      type="text"
                      placeholder="Enter video name"
                      value={videoName}
                      onChange={(e) => setVideoName(e.target.value)}
                      className="bg-black/40 border-white/10 text-white rounded-xl"
                    />
                    <Button
                      onClick={handleSaveVideo}
                      className="flex items-center gap-2 bg-purple-600 hover:bg-purple-700 rounded-xl"
                      disabled={!videoName}
                    >
                      <Save className="w-4 h-4" />
                      Save
                    </Button>
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>
        <ChatInterface timestamps={timestamps} />
      </div>
    </div>
  )
}

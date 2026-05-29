cat > /home/claude/page.tsx << 'ENDOFFILE'
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
  const [isClient, setIsClient] = useState(false)

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

  // FIX: All mutable data used inside RAF loops and async callbacks must be refs, not state
  const mlModelsReadyRef = useRef<boolean>(false)
  const currentPoseKeypointsRef = useRef<Keypoint[]>([])
  const prevPoseKeypointsRef = useRef<Keypoint[] | null>(null)
  const currentFaceDetectedRef = useRef<boolean>(false)
  const currentFaceConfidenceRef = useRef<number | undefined>(undefined)
  const transcriptRef = useRef<string>('')

  // Keep transcriptRef in sync with transcript state
  useEffect(() => {
    transcriptRef.current = transcript
  }, [transcript])

  // -----------------------------
  // 1) Initialize ML Models
  // -----------------------------
  const initMLModels = async () => {
    if (typeof window === 'undefined') return

    try {
      setIsInitializing(true)
      mlModelsReadyRef.current = false
      setMlModelsReady(false)
      setError(null)

      setInitializationProgress('Loading TensorFlow.js modules...')
      tfModules = await loadTensorFlowModules()

      if (!tfModules) {
        throw new Error('Failed to load TensorFlow.js modules')
      }

      setInitializationProgress('Initializing AI models...')
      const [faceModel, poseModel] = await Promise.all([
        tfModules.blazefaceModel.load({
          maxFaces: 1,
          scoreThreshold: 0.5
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

      mlModelsReadyRef.current = true
      setMlModelsReady(true)
      setIsInitializing(false)
      console.log('All ML models loaded successfully')
    } catch (err) {
      console.error('Error loading ML models:', err)
      setError('Failed to load ML models: ' + (err as Error).message)
      mlModelsReadyRef.current = false
      setMlModelsReady(false)
      setIsInitializing(false)
    }
  }

  const updateCanvasSize = () => {
    if (!videoRef.current || !canvasRef.current) return
    const canvas = canvasRef.current
    canvas.width = 640
    canvas.height = 360
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

        await new Promise<void>((resolve) => {
          videoRef.current!.onloadedmetadata = () => {
            updateCanvasSize()
            resolve()
          }
        })
      }
    } catch (error) {
      console.error("Error accessing webcam:", error)
      setError("Failed to access webcam. Please make sure you have granted camera permissions.")
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
  // FIX: Use refs throughout — no stale closures
  // -----------------------------
  const runDetection = async () => {
    if (!isRecordingRef.current) return

    // FIX: Read from ref, not state — state is always stale inside RAF
    if (!mlModelsReadyRef.current || !faceModelRef.current || !poseModelRef.current) {
      detectionFrameRef.current = requestAnimationFrame(runDetection)
      return
    }

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

    ctx.clearRect(0, 0, canvas.width, canvas.height)
    drawVideoToCanvas(video, canvas, ctx)

    const scaleX = canvas.width / video.videoWidth
    const scaleY = canvas.height / video.videoHeight

    // Face detection — write result to ref for analyzeFrame to consume
    if (faceModelRef.current) {
      try {
        const predictions = await faceModelRef.current.estimateFaces(video, false)
        currentFaceDetectedRef.current = predictions.length > 0
        currentFaceConfidenceRef.current = predictions.length > 0
          ? (predictions[0].probability as number)
          : undefined

        predictions.forEach((prediction: blazeface.NormalizedFace) => {
          const start = prediction.topLeft as [number, number]
          const end = prediction.bottomRight as [number, number]
          const size = [end[0] - start[0], end[1] - start[1]]
          const scaledStart = [start[0] * scaleX, start[1] * scaleY]
          const scaledSize = [size[0] * scaleX, size[1] * scaleX]

          ctx.strokeStyle = "rgba(0, 255, 0, 0.8)"
          ctx.lineWidth = 2
          ctx.strokeRect(scaledStart[0], scaledStart[1], scaledSize[0], scaledSize[1])

          const confidence = Math.round((prediction.probability as number) * 100)
          ctx.fillStyle = "white"
          ctx.font = "16px Arial"
          ctx.fillText(`${confidence}%`, scaledStart[0], scaledStart[1] - 5)
        })
      } catch (err) {
        console.error("Face detection error:", err)
      }
    }

    // Pose detection — write result to ref for analyzeFrame to consume
    if (poseModelRef.current) {
      try {
        const poses = await poseModelRef.current.estimatePoses(video)
        if (poses.length > 0) {
          const keypoints = poses[0].keypoints
          const convertedKeypoints: Keypoint[] = keypoints.map(kp => ({
            x: kp.x,
            y: kp.y,
            score: kp.score ?? 0,
            name: kp.name
          }))

          // FIX: Update prev before updating current, both via refs only
          prevPoseKeypointsRef.current = currentPoseKeypointsRef.current
          currentPoseKeypointsRef.current = convertedKeypoints

          keypoints.forEach((keypoint) => {
            if ((keypoint.score ?? 0) > 0.3) {
              const x = keypoint.x * scaleX
              const y = keypoint.y * scaleY

              ctx.beginPath()
              ctx.arc(x, y, 4, 0, 2 * Math.PI)
              ctx.fillStyle = "rgba(255, 0, 0, 0.8)"
              ctx.fill()

              ctx.beginPath()
              ctx.arc(x, y, 6, 0, 2 * Math.PI)
              ctx.strokeStyle = "white"
              ctx.lineWidth = 1.5
              ctx.stroke()

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

    lastFrameTimeRef.current = performance.now()
    detectionFrameRef.current = requestAnimationFrame(runDetection)
  }

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
  // 5) Analyze frame via API
  // FIX: Read all live data from refs, not stale state closures
  // -----------------------------
  const analyzeFrame = async () => {
    if (!isRecordingRef.current) return

    const canvas = canvasRef.current
    if (!canvas) return

    // FIX: Read from refs — these are always current
    const currentTranscript = transcriptRef.current.trim()
    const poseKeypoints = currentPoseKeypointsRef.current
    const faceDetected = currentFaceDetectedRef.current
    const faceConfidence = currentFaceConfidenceRef.current

    // FIX: Run frame filter BEFORE capturing a separate frame
    // The canvas already has the latest frame drawn by runDetection
    const filterResult = frameFilter.evaluate(
      canvas,
      {
        poseKeypoints,
        prevPoseKeypoints: prevPoseKeypointsRef.current,
        faceDetected,
        faceConfidence,
        transcript: currentTranscript,
        frameHeight: canvas.height
      }
    )

    console.log("Frame Filter:", filterResult)

    if (!filterResult.send) return

    try {
      const frame = await captureFrame()
      if (!frame) return

      if (!frame.startsWith("data:image/jpeg")) {
        console.error("Invalid frame format")
        return
      }

      const tensorflowData: TensorFlowData = {
        poseKeypoints,
        faceDetected,
        faceConfidence
      }

      console.log('Sending frame to GPT — filter score:', filterResult.score, 'reason:', filterResult.reason)

      const result = await detectEvents(frame, currentTranscript, tensorflowData)

      if (!isRecordingRef.current) return

      if (!result || !result.events) {
        console.warn("No events returned from detectEvents")
        return
      }

      if (result.events.length > 0) {
        for (const event of result.events) {
          const newTimestamp = {
            timestamp: getElapsedTime(),
            description: event.description,
            isDangerous: event.isDangerous
          }

          console.log("Adding new timestamp:", newTimestamp)
          setTimestamps((prev) => [...prev, newTimestamp])

          if (event.isDangerous) {
            console.log("DANGEROUS EVENT DETECTED — Sending notifications...")
            const notificationPayload = {
              title: "Dangerous Activity Detected",
              description: `At ${newTimestamp.timestamp}, the following dangerous activity was detected: ${event.description}`,
              timestamp: newTimestamp.timestamp,
              imageBase64: frame
            }

            try {
              const telegramResponse = await fetch("/api/send-telegram", {
                method: "POST",
                headers: { "Content-Type": "application/json", Accept: "application/json" },
                body: JSON.stringify(notificationPayload)
              })
              if (telegramResponse.ok) {
                console.log("Telegram notification sent successfully")
              } else {
                const telegramError = await telegramResponse.json()
                console.error("Failed to send Telegram notification:", telegramError)
              }
            } catch (telegramError) {
              console.error("Error sending Telegram notification:", telegramError)
            }

            try {
              const whatsappResponse = await fetch("/api/send-whatsapp", {
                method: "POST",
                headers: { "Content-Type": "application/json", Accept: "application/json" },
                body: JSON.stringify(notificationPayload)
              })
              if (whatsappResponse.ok) {
                console.log("WhatsApp notification sent successfully")
              } else {
                const whatsappError = await whatsappResponse.json()
                console.error("Failed to send WhatsApp notification:", whatsappError)
              }
            } catch (whatsappError) {
              console.error("Error sending WhatsApp notification:", whatsappError)
            }

            try {
              const emailPayload = {
                title: notificationPayload.title,
                description: notificationPayload.description
              }
              const response = await fetch("/api/send-email", {
                method: "POST",
                headers: { "Content-Type": "application/json", Accept: "application/json" },
                body: JSON.stringify(emailPayload)
              })

              if (!response.ok) {
                if (response.status === 401) {
                  setError("Please sign in to receive email notifications for dangerous events.")
                } else if (response.status === 500) {
                  setError("Email service not properly configured. Please contact support.")
                } else {
                  const errorText = await response.text()
                  console.error("Failed to send email notification:", errorText)
                  setError("Failed to send email notification. Please try again later.")
                }
                continue
              }

              const resData = await response.json()
              console.log("Email notification sent successfully:", resData)
            } catch (error) {
              console.error("Error sending email notification:", error)
            }
          }
        }
      }
    } catch (error) {
      console.error("Error analyzing frame:", error)
      setError("Error analyzing frame. Please try again.")
      if (isRecordingRef.current) {
        stopRecording()
      }
    }
  }

  // -----------------------------
  // 6) Capture current video frame
  // -----------------------------
  const captureFrame = async (): Promise<string | null> => {
    if (!videoRef.current) return null

    const video = videoRef.current
    const tempCanvas = document.createElement("canvas")
    tempCanvas.width = 640
    tempCanvas.height = 360

    const context = tempCanvas.getContext("2d")
    if (!context) return null

    try {
      context.drawImage(video, 0, 0, 640, 360)
      return tempCanvas.toDataURL("image/jpeg", 0.8)
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
    const elapsed = Math.floor((Date.now() - startTimeRef.current.getTime()) / 1000)
    setCurrentTime(elapsed)
    const minutes = Math.floor(elapsed / 60)
    const seconds = elapsed % 60
    return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
  }

  // -----------------------------
  // 8) Recording control
  // -----------------------------
  const startRecording = async () => {
    setCurrentTime(0)
    setVideoDuration(0)

    if (!mlModelsReadyRef.current) {
      console.log("Loading TensorFlow models on demand...")
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

    // Reset all live data refs
    currentPoseKeypointsRef.current = []
    prevPoseKeypointsRef.current = null
    currentFaceDetectedRef.current = false
    currentFaceConfidenceRef.current = undefined

    startTimeRef.current = new Date()
    isRecordingRef.current = true
    setIsRecording(true)

    if (durationIntervalRef.current) clearInterval(durationIntervalRef.current)
    durationIntervalRef.current = setInterval(() => {
      if (isRecordingRef.current) {
        const elapsed = Math.floor((Date.now() - startTimeRef.current!.getTime()) / 1000)
        setVideoDuration(elapsed)
      }
    }, 1000)

    if (recognitionRef.current) {
      setTranscript("")
      transcriptRef.current = ""
      setIsTranscribing(true)
      recognitionRef.current.start()
    }

    // FIX: Set up MediaRecorder handlers once only — no duplicate assignments
    recordedChunksRef.current = []

    const getSupportedMimeType = () => {
      const types = [
        'video/webm;codecs=vp9,opus',
        'video/webm;codecs=vp8,opus',
        'video/webm;codecs=vp9',
        'video/webm;codecs=vp8',
        'video/webm'
      ]
      for (const type of types) {
        if (MediaRecorder.isTypeSupported(type)) return type
      }
      return 'video/webm'
    }

    const mimeType = getSupportedMimeType()
    console.log('Using MediaRecorder mimeType:', mimeType)

    const mediaRecorder = new MediaRecorder(mediaStreamRef.current, { mimeType })

    // FIX: Assign handlers once
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
    mediaRecorder.start(1000)

    if (detectionFrameRef.current) cancelAnimationFrame(detectionFrameRef.current)

    // FIX: Use ref, not state, to check if models are ready
    if (mlModelsReadyRef.current) {
      lastDetectionTime.current = 0
      detectionFrameRef.current = requestAnimationFrame(runDetection)
    } else {
      console.warn("ML models not ready yet, detection will start once loaded")
    }

    if (analysisIntervalRef.current) clearInterval(analysisIntervalRef.current)
    analyzeFrame()
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

    if (mediaRecorderRef.current && mediaRecorderRef.current.state !== "inactive") {
      mediaRecorderRef.current.stop()
    }

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
  // 9) Save video
  // -----------------------------
  const handleSaveVideo = () => {
    if (!recordedVideoUrl || !videoName) return

    try {
      const savedVideos: SavedVideo[] = JSON.parse(localStorage.getItem("savedVideos") || "[]")
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

  useEffect(() => {
    const video = videoRef.current
    if (!video) return

    const handleTimeUpdate = () => setCurrentTime(video.currentTime)
    const handleLoadedMetadata = () => {
      setVideoDuration(video.duration || 60)
      video.currentTime = 0
    }

    video.addEventListener('timeupdate', handleTimeUpdate)
    video.addEventListener('loadedmetadata', handleLoadedMetadata)
    video.currentTime = 0

    return () => {
      video.removeEventListener('timeupdate', handleTimeUpdate)
      video.removeEventListener('loadedmetadata', handleLoadedMetadata)
    }
  }, [recordedVideoUrl])

  useEffect(() => {
    if (typeof window === 'undefined') return

    initSpeechRecognition()
    const init = async () => {
      await startWebcam()
      console.log("Webcam ready. TensorFlow will load when you click Start Recording.")
      setIsInitializing(false)
    }
    init()

    return () => {
      stopWebcam()
      if (analysisIntervalRef.current) clearInterval(analysisIntervalRef.current)
      if (detectionFrameRef.current) cancelAnimationFrame(detectionFrameRef.current)
    }
  }, [isClient])

  // Start detection when ML models become ready mid-recording
  useEffect(() => {
    if (mlModelsReady && isRecordingRef.current && !detectionFrameRef.current) {
      console.log("Starting TensorFlow detection — models now ready")
      lastDetectionTime.current = 0
      detectionFrameRef.current = requestAnimationFrame(runDetection)
    }
  }, [mlModelsReady])

  // -----------------------------
  // Render
  // -----------------------------
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
                          const [m, s] = ts.timestamp.split(':').map(Number)
                          return {
                            startTime: m * 60 + s,
                            endTime: m * 60 + s + 3,
                            type: ts.isDangerous ? 'warning' : 'normal',
                            label: ts.description
                          }
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
ENDOFFILE
echo "Done"
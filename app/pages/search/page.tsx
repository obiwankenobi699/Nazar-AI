"use client"

import { useState, useEffect, useRef } from "react"
import { Trash2, RefreshCw } from "lucide-react"
import { ChatMessage } from "@/components/ChatMessage"
import { ChatInput } from "@/components/ChatInput"

interface Result {
  id: string
  timestamp: string
  cameraId: string
  description: string
  distance: number
  thumbBase64: string
}

interface ChatEntry {
  type: "query" | "result" | "error" | "loading"
  content: string | Result[]
  query?: string
  imageBase64?: string
}

const EXAMPLE_QUERIES = [
  "person clutching chest",
  "someone fell on ground",
  "suspicious activity",
  "person running",
  "dark scene no one visible",
]

export default function SearchPage() {
  const [query,       setQuery]      = useState("")
  const [loading,     setLoading]    = useState(false)
  const [stats,       setStats]      = useState<{ total_frames: number; model: string } | null>(null)
  const [clearing,    setClearing]   = useState(false)
  const [chatHistory, setChatHistory] = useState<ChatEntry[]>([])
  const bottomRef = useRef<HTMLDivElement>(null)

  const fetchStats = () => {
    fetch("/api/search")
      .then(r => r.json())
      .then(d => { if (!d.error) setStats(d) })
      .catch(() => {})
  }

  useEffect(() => {
    fetchStats()
  }, [])

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" })
  }, [chatHistory])

  const pushResults = (data: any, queryLabel: string) => {
    setChatHistory(prev => prev.filter(e => e.type !== "loading"))
    const hits: Result[] = data.results ?? []
    if (!hits.length) {
      setChatHistory(prev => [...prev, { type: "error", content: "No matching frames found." }])
    } else {
      setChatHistory(prev => [...prev, { type: "result", content: hits, query: queryLabel }])
    }
  }

  const pushError = (msg: string) => {
    setChatHistory(prev => prev.filter(e => e.type !== "loading"))
    setChatHistory(prev => [...prev, { type: "error", content: msg }])
  }

  /* ── Text search ── */
  const handleSearch = async (q?: string) => {
    const finalQuery = (q ?? query).trim()
    if (!finalQuery) return
    if (q) setQuery(q)

    setChatHistory(prev => [...prev, { type: "query", content: finalQuery }])
    setChatHistory(prev => [...prev, { type: "loading", content: "" }])
    setLoading(true)

    try {
      const res = await fetch("/api/search", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: finalQuery, topK: 9 }),
      })
      const data = await res.json()
      if (!res.ok) { pushError(data.error || "Search failed"); return }
      pushResults(data, finalQuery)
    } catch {
      pushError("Search failed — is the embedder running?")
    } finally {
      setLoading(false)
    }
  }

  /* ── Image search ── */
  const handleImageSearch = async (base64: string) => {
    setChatHistory(prev => [...prev, { type: "query", content: "[image search]", imageBase64: base64 }])
    setChatHistory(prev => [...prev, { type: "loading", content: "" }])
    setLoading(true)

    try {
      const res = await fetch("/api/search", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ imageBase64: base64, topK: 9 }),
      })
      const data = await res.json()
      if (!res.ok) { pushError(data.error || "Search failed"); return }
      pushResults(data, "[image search]")
    } catch {
      pushError("Search failed — is the embedder running?")
    } finally {
      setLoading(false)
    }
  }

  /* ── Clear ── */
  const handleClear = async () => {
    if (!confirm("Clear all indexed frames?")) return
    setClearing(true)
    try {
      await fetch("/api/search", { method: "DELETE" })
      setChatHistory([])
      fetchStats()
    } catch {
      pushError("Could not clear")
    } finally {
      setClearing(false)
    }
  }

  return (
    <div className="flex flex-col h-screen bg-[#0f0f0f] text-white">

      {/* Top bar */}
      <div className="flex-shrink-0 flex items-center justify-between px-5 py-2.5 border-b border-white/[0.06]">
        <div className="flex items-center gap-2.5">
          <span className="text-sm font-semibold text-white/90 tracking-tight">Footage Search</span>
          {stats && (
            <span className="text-xs text-white/30 font-mono">
              {stats.total_frames} frames · {stats.model}
            </span>
          )}
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={fetchStats}
            className="p-1.5 rounded-md text-white/20 hover:text-white/50 hover:bg-white/5 transition-all"
          >
            <RefreshCw className="w-3.5 h-3.5" />
          </button>
          {stats && stats.total_frames > 0 && (
            <button
              onClick={handleClear}
              disabled={clearing}
              className="p-1.5 rounded-md text-white/20 hover:text-red-400/70 hover:bg-red-400/5 transition-all disabled:opacity-30"
            >
              <Trash2 className="w-3.5 h-3.5" />
            </button>
          )}
        </div>
      </div>

      {/* Message area */}
      <div className="flex-1 overflow-y-auto">
        <div className="max-w-3xl mx-auto px-4 py-8 flex flex-col gap-8">

          {/* Welcome state */}
          {chatHistory.length === 0 && (
            <div className="flex flex-col items-center justify-center min-h-[55vh] gap-8 text-center">
              <div>
                <p className="text-2xl font-semibold text-white/80 mb-2 tracking-tight">
                  What are you looking for?
                </p>
                <p className="text-sm text-white/30 max-w-xs mx-auto leading-relaxed">
                  Describe a scene or behaviour, or upload an image — AI will find matching frames from your footage.
                </p>
              </div>
              <div className="flex flex-wrap gap-2 justify-center">
                {EXAMPLE_QUERIES.map((q) => (
                  <button
                    key={q}
                    onClick={() => handleSearch(q)}
                    className="text-xs px-4 py-2 rounded-full border border-white/10 text-white/40 hover:text-white/80 hover:border-white/25 hover:bg-white/5 transition-all"
                  >
                    {q}
                  </button>
                ))}
              </div>
            </div>
          )}

          {/* Messages */}
          {chatHistory.map((entry, idx) => (
            <ChatMessage
              key={idx}
              type={entry.type}
              content={entry.content}
              query={entry.query}
              imageBase64={entry.imageBase64}
            />
          ))}

          <div ref={bottomRef} />
        </div>
      </div>

      {/* Input */}
      <ChatInput
        onSend={handleSearch}
        onSendImage={handleImageSearch}
        loading={loading}
      />
    </div>
  )
}
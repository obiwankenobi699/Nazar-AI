"use client"

import { useState, useEffect, useRef } from "react"
import { Search, Database, Loader2, AlertCircle, Clock, Trash2, RefreshCw } from "lucide-react"
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
}

const EXAMPLE_QUERIES = [
  "person clutching chest",
  "someone fell on ground",
  "suspicious activity",
  "person running",
  "dark scene no one visible",
]

export default function SearchPage() {
  const [chatHistory, setChatHistory] = useState<ChatEntry[]>([])
  const [loading, setLoading] = useState(false)
  const [stats, setStats] = useState<{ total_frames: number; model: string } | null>(null)
  const [clearing, setClearing] = useState(false)
  const mainRef = useRef<HTMLDivElement>(null)

  const fetchStats = () => {
    fetch('/api/search')
      .then(r => r.json())
      .then(d => { if (!d.error) setStats(d) })
      .catch(() => {})
  }

  useEffect(() => {
    fetchStats()
  }, [])

  useEffect(() => {
    if (mainRef.current) {
      mainRef.current.scrollTop = mainRef.current.scrollHeight
    }
  }, [chatHistory])

  const handleSearch = async (query: string) => {
    if (!query.trim()) return
    setChatHistory(prev => [...prev, { type: "query", content: query }])
    setLoading(true)
    setChatHistory(prev => [...prev, { type: "loading", content: "Loading..." }])
    try {
      const res = await fetch('/api/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ query, topK: 9 }),
      })
      const data = await res.json()
      setChatHistory(prev => {
        // Remove last loading entry
        const withoutLoading = prev.filter(entry => entry.type !== "loading")
        if (!res.ok) {
          return [...withoutLoading, { type: "error", content: data.error || "Search failed" }]
        }
        if (!data.results?.length) {
          return [...withoutLoading, { type: "error", content: "No matching frames found." }]
        }
        return [...withoutLoading, { type: "result", content: data.results, query }]
      })
    } catch {
      setChatHistory(prev => {
        const withoutLoading = prev.filter(entry => entry.type !== "loading")
        return [...withoutLoading, { type: "error", content: "Search failed — is the embedder running?" }]
      })
    } finally {
      setLoading(false)
      fetchStats()
    }
  }

  const handleClear = async () => {
    if (!confirm('Clear all indexed frames?')) return
    setClearing(true)
    try {
      await fetch('/api/search', { method: 'DELETE' })
      setChatHistory([])
      fetchStats()
    } catch {
      setChatHistory(prev => [...prev, { type: "error", content: "Could not clear" }])
    } finally {
      setClearing(false)
    }
  }

  return (
    <div className="min-h-screen bg-black text-white flex flex-col">
      <header className="p-6 border-b border-zinc-700">
        <h1 className="text-3xl font-bold drop-shadow-[0_0_10px_rgba(255,255,255,0.4)]">Footage Search</h1>
        <p className="text-zinc-500 text-sm mt-1">Semantic search over recorded frames · powered by local Ollama embeddings</p>
        <div className="flex items-center justify-between mt-4 text-xs font-mono text-zinc-500">
          {stats ? (
            <>
              <span><span className="text-white">{stats.total_frames}</span> frames indexed</span>
              <span>model <span className="text-purple-400">{stats.model}</span></span>
            </>
          ) : (
            <span className="text-zinc-600">checking embedder...</span>
          )}
          <div className="flex gap-2">
            <button onClick={fetchStats} className="text-zinc-600 hover:text-zinc-400 p-1">
              <RefreshCw className="w-4 h-4" />
            </button>
            {stats && stats.total_frames > 0 && (
              <button onClick={handleClear} disabled={clearing}
                className="text-zinc-600 hover:text-red-400 p-1 transition-colors">
                <Trash2 className="w-4 h-4" />
              </button>
            )}
          </div>
        </div>
      </header>

      <main
        ref={mainRef}
        className="flex-1 overflow-y-auto px-6 py-4 flex flex-col gap-2"
      >
        {chatHistory.length === 0 && (
          <div className="flex flex-wrap gap-2 mb-8 justify-center">
            {EXAMPLE_QUERIES.map(q => (
              <button key={q} onClick={() => handleSearch(q)}
                className="text-xs px-3 py-1.5 bg-zinc-900/60 border border-white/5 rounded-full text-zinc-400 hover:text-white hover:border-white/20 transition-colors">
                {q}
              </button>
            ))}
          </div>
        )}
        {chatHistory.map((entry, idx) => (
          <ChatMessage key={idx} type={entry.type} content={entry.content} query={entry.query} />
        ))}
      </main>

      <ChatInput onSend={handleSearch} loading={loading} />
    </div>
  )
}
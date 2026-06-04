"use client"

import React, { ReactNode } from "react"
import { Clock } from "lucide-react"

interface Result {
  id: string
  timestamp: string
  cameraId: string
  description: string
  distance: number
  thumbBase64: string
}

interface ChatMessageProps {
  type: "query" | "result" | "error" | "loading"
  content: string | Result[]
  query?: string
}

const relColor = (d: number) =>
  d < 0.25 ? "text-green-400" : d < 0.55 ? "text-yellow-400" : "text-red-400"

const relLabel = (d: number) =>
  d < 0.25 ? "Strong match" : d < 0.55 ? "Partial match" : "Weak match"

export function ChatMessage({ type, content, query }: ChatMessageProps) {
  if (type === "query") {
    return (
      <div className="self-end max-w-[80%] bg-purple-600 text-white rounded-2xl px-4 py-2 mb-2 shadow-md">
        {content as string}
      </div>
    )
  }

  if (type === "loading") {
    return (
      <div className="self-start max-w-[80%] bg-zinc-800 text-zinc-400 rounded-2xl px-4 py-2 mb-2 shadow-md italic">
        Loading...
      </div>
    )
  }

  if (type === "error") {
    return (
      <div className="self-start max-w-[80%] bg-red-900/80 text-red-400 rounded-2xl px-4 py-2 mb-2 shadow-md">
        {content as string}
      </div>
    )
  }

  if (type === "result" && Array.isArray(content)) {
    if (content.length === 0) {
      return (
        <div className="self-start max-w-[80%] bg-zinc-800 text-zinc-400 rounded-2xl px-4 py-2 mb-2 shadow-md italic">
          No results found for &ldquo;{query}&rdquo;.
        </div>
      )
    }

    return (
      <div className="self-start max-w-[80%] bg-zinc-900/80 rounded-2xl px-4 py-3 mb-4 shadow-md">
        <p className="text-xs text-zinc-400 mb-2 font-mono">
          {content.length} results for &ldquo;{query}&rdquo;
        </p>
        <div className="flex flex-col gap-3 max-h-96 overflow-y-auto">
          {content.map((r) => (
            <div
              key={r.id}
              className="flex gap-3 bg-zinc-800 rounded-lg p-2 hover:bg-zinc-700 transition-colors"
            >
              {r.thumbBase64 ? (
                <img
                  src={r.thumbBase64}
                  alt={`Frame at ${r.timestamp}`}
                  className="w-24 aspect-video object-cover rounded-md bg-zinc-700"
                />
              ) : (
                <div className="w-24 aspect-video bg-zinc-700 flex items-center justify-center rounded-md">
                  <Clock className="w-6 h-6 text-zinc-500" />
                </div>
              )}
              <div className="flex flex-col flex-1">
                <div className="flex items-center gap-2 mb-1 text-xs text-zinc-400 font-mono">
                  <Clock className="w-3 h-3" />
                  <span>{r.timestamp}</span>
                  <span>{r.cameraId}</span>
                </div>
                {r.description && (
                  <p className="text-xs text-zinc-300 line-clamp-3 mb-1">{r.description}</p>
                )}
                <div className="flex items-center justify-between text-xs">
                  <span className={`font-medium ${relColor(r.distance)}`}>
                    {relLabel(r.distance)}
                  </span>
                  <span className="font-mono text-zinc-600">
                    {(1 - r.distance).toFixed(2)}
                  </span>
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>
    )
  }

  return null
}
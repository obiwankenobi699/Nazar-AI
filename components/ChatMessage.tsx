"use client"

import React from "react"
import { Clock, Video, AlertCircle } from "lucide-react"

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
  imageBase64?: string
}

const matchBadge = (d: number) => {
  if (d < 0.25) return { label: "Strong", cls: "text-emerald-400 bg-emerald-400/8 border-emerald-400/15" }
  if (d < 0.55) return { label: "Partial", cls: "text-amber-400 bg-amber-400/8 border-amber-400/15" }
  return { label: "Weak", cls: "text-red-400 bg-red-400/8 border-red-400/15" }
}

function Dots() {
  return (
    <div className="flex gap-1 items-center h-5">
      {[0, 1, 2].map((i) => (
        <span
          key={i}
          className="block w-1.5 h-1.5 rounded-full bg-white/25 animate-bounce"
          style={{ animationDelay: `${i * 0.18}s`, animationDuration: "0.8s" }}
        />
      ))}
    </div>
  )
}

function AIMark() {
  return (
    <div className="w-7 h-7 rounded-full bg-gradient-to-br from-violet-500 to-indigo-600 flex items-center justify-center flex-shrink-0 shadow-lg shadow-violet-900/30">
      <Video className="w-3 h-3 text-white" />
    </div>
  )
}

export function ChatMessage({ type, content, query, imageBase64 }: ChatMessageProps) {

  /* ── User query ── */
  if (type === "query") {
    if (imageBase64) {
      return (
        <div className="flex justify-end">
          <div className="max-w-[75%] bg-white/[0.07] rounded-2xl rounded-br-md overflow-hidden border border-white/[0.09]">
            <img
              src={imageBase64}
              alt="Image search"
              className="w-full max-h-48 object-cover"
            />
            <p className="text-xs text-white/30 px-3 py-1.5 text-right tracking-wide">
              image search
            </p>
          </div>
        </div>
      )
    }
    return (
      <div className="flex justify-end">
        <div className="max-w-[75%] bg-white/[0.07] text-white/90 text-sm leading-relaxed px-4 py-2.5 rounded-2xl rounded-br-md">
          {content as string}
        </div>
      </div>
    )
  }

  /* ── Loading ── */
  if (type === "loading") {
    return (
      <div className="flex items-start gap-3">
        <AIMark />
        <div className="pt-1">
          <Dots />
        </div>
      </div>
    )
  }

  /* ── Error ── */
  if (type === "error") {
    return (
      <div className="flex items-start gap-3">
        <AIMark />
        <div className="flex items-center gap-2 text-sm text-red-400/80 bg-red-400/5 border border-red-400/10 px-4 py-2.5 rounded-2xl rounded-tl-md max-w-[75%]">
          <AlertCircle className="w-3.5 h-3.5 flex-shrink-0" />
          {content as string}
        </div>
      </div>
    )
  }

  /* ── Results ── */
  if (type === "result" && Array.isArray(content)) {
    if (content.length === 0) {
      return (
        <div className="flex items-start gap-3">
          <AIMark />
          <p className="text-sm text-white/30 pt-0.5 italic">
            No results found for "{query}".
          </p>
        </div>
      )
    }

    return (
      <div className="flex items-start gap-3">
        <AIMark />
        <div className="flex-1 min-w-0">
          <p className="text-sm text-white/50 mb-4 leading-relaxed">
            Found{" "}
            <span className="text-white/80 font-medium">{content.length}</span>{" "}
            {content.length === 1 ? "frame" : "frames"} matching{" "}
            {query === "[image search]"
              ? <span className="text-violet-400">uploaded image</span>
              : <span className="text-violet-400">"{query}"</span>
            }
          </p>

          <div className="flex flex-col gap-2">
            {content.map((r) => {
              const badge = matchBadge(r.distance)
              const ts = r.timestamp ? new Date(r.timestamp) : null
              const timeStr =
                ts && !isNaN(ts.getTime())
                  ? ts.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })
                  : r.timestamp || "—"

              return (
                <div
                  key={r.id}
                  className="group flex gap-3.5 p-3 rounded-xl border border-white/[0.06] bg-white/[0.03] hover:bg-white/[0.06] hover:border-white/[0.12] transition-all duration-200 cursor-pointer"
                >
                  <div className="flex-shrink-0 w-32 aspect-video rounded-lg overflow-hidden bg-white/5">
                    {r.thumbBase64 ? (
                      <img
                        src={r.thumbBase64}
                        alt={`Frame ${r.cameraId} at ${timeStr}`}
                        className="w-full h-full object-cover group-hover:scale-[1.03] transition-transform duration-300"
                      />
                    ) : (
                      <div className="w-full h-full flex items-center justify-center">
                        <Video className="w-5 h-5 text-white/15" />
                      </div>
                    )}
                  </div>

                  <div className="flex flex-col flex-1 min-w-0 justify-between py-0.5">
                    <div className="flex items-center gap-2 text-xs font-mono text-white/30 mb-2">
                      <Clock className="w-3 h-3" />
                      <span>{timeStr}</span>
                      <span className="text-violet-400/70">{r.cameraId}</span>
                    </div>

                    {r.description && (
                      <p className="text-xs text-white/60 leading-relaxed line-clamp-2 mb-3">
                        {r.description}
                      </p>
                    )}

                    <div className="flex items-center justify-between">
                      <span className={`text-[11px] font-medium px-2 py-0.5 rounded-full border ${badge.cls}`}>
                        {badge.label} match
                      </span>
                      <span className="text-[11px] font-mono text-white/20">
                        {(1 - r.distance).toFixed(2)}
                      </span>
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      </div>
    )
  }

  return null
}
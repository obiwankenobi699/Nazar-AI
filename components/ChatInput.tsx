"use client"

import React, { useState, useRef, useEffect, FormEvent, KeyboardEvent } from "react"
import { Send, Loader2 } from "lucide-react"

interface ChatInputProps {
  onSend: (message: string) => void
  loading: boolean
}

export function ChatInput({ onSend, loading }: ChatInputProps) {
  const [input, setInput] = useState("")
  const textareaRef = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    textareaRef.current?.focus()
  }, [])

  const resize = () => {
    const el = textareaRef.current
    if (!el) return
    el.style.height = "auto"
    el.style.height = Math.min(el.scrollHeight, 140) + "px"
  }

  const handleChange = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    setInput(e.target.value)
    resize()
  }

  const handleSubmit = (e?: FormEvent) => {
    e?.preventDefault()
    const trimmed = input.trim()
    if (!trimmed || loading) return
    onSend(trimmed)
    setInput("")
    // Reset height
    if (textareaRef.current) textareaRef.current.style.height = "auto"
  }

  const handleKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault()
      handleSubmit()
    }
  }

  const canSend = input.trim().length > 0 && !loading

  return (
    <div className="flex-shrink-0 pb-6 pt-3 px-4">
      {/* Same max-width as the message column */}
      <div className="max-w-3xl mx-auto">
        <div className="relative flex items-end gap-3 bg-white/[0.05] border border-white/[0.09] rounded-2xl px-4 py-3 focus-within:border-white/20 focus-within:bg-white/[0.07] transition-all duration-200 shadow-[0_0_0_1px_rgba(255,255,255,0)] focus-within:shadow-[0_0_30px_rgba(139,92,246,0.08)]">
          <textarea
            ref={textareaRef}
            value={input}
            onChange={handleChange}
            onKeyDown={handleKeyDown}
            placeholder="Describe what you're looking for…"
            rows={1}
            disabled={loading}
            className="flex-1 bg-transparent resize-none outline-none border-none text-sm text-white/80 placeholder-white/20 leading-relaxed overflow-y-auto"
            style={{ maxHeight: "140px", scrollbarWidth: "none" }}
          />
          <button
            onClick={() => handleSubmit()}
            disabled={!canSend}
            className={`
              flex-shrink-0 w-8 h-8 rounded-lg flex items-center justify-center transition-all duration-200
              ${canSend
                ? "bg-violet-600 hover:bg-violet-500 text-white shadow-lg shadow-violet-900/40 scale-100"
                : "bg-white/5 text-white/20 cursor-not-allowed scale-95"
              }
            `}
          >
            {loading
              ? <Loader2 className="w-3.5 h-3.5 animate-spin" />
              : <Send className="w-3.5 h-3.5" />
            }
          </button>
        </div>
        <p className="text-center text-[11px] text-white/15 mt-2.5 tracking-wide">
          Enter to search &nbsp;·&nbsp; Shift + Enter for new line
        </p>
      </div>
    </div>
  )
}
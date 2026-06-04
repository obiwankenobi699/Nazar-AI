"use client"

import React, { useState, useRef, useEffect, FormEvent } from "react"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Loader2 } from "lucide-react"

interface ChatInputProps {
  onSend: (message: string) => void
  loading: boolean
}

export function ChatInput({ onSend, loading }: ChatInputProps) {
  const [input, setInput] = useState("")
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault()
    const trimmed = input.trim()
    if (!trimmed || loading) return
    onSend(trimmed)
    setInput("")
  }

  return (
    <form onSubmit={handleSubmit} className="flex gap-3 p-4 bg-zinc-900 border-t border-zinc-700">
      <Input
        ref={inputRef}
        value={input}
        onChange={(e) => setInput(e.target.value)}
        placeholder='Ask anything... e.g. "person running"'
        className="flex-1 bg-zinc-800 border-none focus:ring-0 focus-visible:ring-0 text-white"
        disabled={loading}
        autoComplete="off"
      />
      <Button type="submit" disabled={loading || !input.trim()} className="flex items-center">
        {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : "Send"}
      </Button>
    </form>
  )
}
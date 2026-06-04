// app/api/embed/route.ts
// Forwards frame from page.tsx to local Python embedder
// Fire-and-forget — page.tsx doesn't await this critically

import { NextRequest, NextResponse } from 'next/server'

const EMBEDDER = process.env.EMBEDDER_URL ?? 'http://localhost:8000'

export async function POST(req: NextRequest) {
  try {
    const body = await req.json()
    const res  = await fetch(`${EMBEDDER}/embed`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
      signal:  AbortSignal.timeout(5000),
    })
    return NextResponse.json(await res.json(), { status: res.ok ? 200 : 502 })
  } catch {
    // Embedder offline — silently ignore, don't break the alert pipeline
    return NextResponse.json({ stored: false, reason: 'embedder_offline' })
  }
}

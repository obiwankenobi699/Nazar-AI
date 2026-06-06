// app/api/search/route.ts
import { NextRequest, NextResponse } from 'next/server'
const EMBEDDER = process.env.EMBEDDER_URL ?? 'http://localhost:8000'

export async function POST(req: NextRequest) {
  try {
    const { query, imageBase64, topK = 6, cameraId } = await req.json()

    if (!query?.trim() && !imageBase64) {
      return NextResponse.json({ error: 'Query required' }, { status: 400 })
    }

    const body: Record<string, unknown> = { topK, cameraId }
    if (imageBase64) {
      body.imageBase64 = imageBase64
    } else {
      body.query = query
    }

    const res = await fetch(`${EMBEDDER}/search`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
      signal:  AbortSignal.timeout(10000),
    })
    if (!res.ok) {
      return NextResponse.json({ error: await res.text() }, { status: 502 })
    }
    return NextResponse.json(await res.json())
  } catch (e: any) {
    const offline = e?.cause?.code === 'ECONNREFUSED' || e?.name === 'TimeoutError'
    return NextResponse.json(
      { error: offline ? 'Embedder offline — run: bash scripts/start-embedder.sh' : String(e) },
      { status: offline ? 503 : 500 }
    )
  }
}

export async function GET() {
  try {
    const res = await fetch(`${EMBEDDER}/stats`, { signal: AbortSignal.timeout(3000) })
    return NextResponse.json(await res.json())
  } catch {
    return NextResponse.json({ error: 'Embedder offline', total_frames: 0 }, { status: 503 })
  }
}

export async function DELETE() {
  try {
    const res = await fetch(`${EMBEDDER}/clear`, {
      method: 'DELETE',
      signal: AbortSignal.timeout(5000),
    })
    return NextResponse.json(await res.json())
  } catch {
    return NextResponse.json({ error: 'Embedder offline' }, { status: 503 })
  }
}
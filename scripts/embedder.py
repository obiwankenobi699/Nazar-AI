"""
scripts/embedder.py  —  Nazar AI Local Embedding Server
FastAPI + ChromaDB + Ollama nomic-embed-text

Endpoints:
  GET  /           — health check
  GET  /stats      — frame count
  POST /embed      — store frame embedding
  POST /search     — semantic search
  DELETE /clear    — wipe collection

Run: bash scripts/start-embedder.sh
"""
import logging
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import chromadb, ollama, base64, io, time, uuid
from PIL import Image

app = FastAPI(title="Nazar Embedder", version="2.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ChromaDB — persisted inside scripts/.chromadb/
chroma     = chromadb.PersistentClient(path=".chromadb")
collection = chroma.get_or_create_collection(
    name="nazar_frames",
    metadata={"hnsw:space": "cosine"},
)

MODEL      = "nomic-embed-text"
MAX_FRAMES = 2000

def check_ollama_connection(retries: int = 5, delay: int = 3):
    for attempt in range(1, retries + 1):
        try:
            # Simple test call to Ollama embeddings API
            _ = ollama.embeddings(model=MODEL, prompt="test")["embedding"]
            logging.info("Connected to Ollama successfully")
            return True
        except Exception as e:
            logging.error(f"Failed to connect to Ollama (attempt {attempt}): {e}")
            if attempt < retries:
                time.sleep(delay)
            else:
                raise

check_ollama_connection()

# ── Models ────────────────────────────────────────────────────────
class EmbedReq(BaseModel):
    imageBase64: str
    timestamp:   str
    cameraId:    str = "cam-0"
    description: str = ""

class SearchReq(BaseModel):
    query:    str
    topK:     int = 6
    cameraId: str | None = None

# ── Helpers ───────────────────────────────────────────────────────
def decode_b64(s: str) -> bytes:
    return base64.b64decode(s.split(",", 1)[1] if "," in s else s)

def thumb(raw: bytes, size=(128, 72)) -> str:
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    img.thumbnail(size, Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=55)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()

def embed(text: str) -> list[float]:
    return ollama.embeddings(model=MODEL, prompt=text)["embedding"]

def frame_description(raw: bytes, extra: str) -> str:
    img = Image.open(io.BytesIO(raw)).convert("RGB").resize((32, 18))
    px  = list(img.getdata())
    r   = sum(p[0] for p in px)/len(px)
    g   = sum(p[1] for p in px)/len(px)
    b   = sum(p[2] for p in px)/len(px)
    br  = (r+g+b)/3
    light = "bright" if br>150 else "dark" if br<80 else "dim"
    color = "red tones" if r>g+30 and r>b+30 else \
            "green tones" if g>r+20 and g>b+20 else \
            "blue tones" if b>r+20 and b>g+20 else "neutral"
    base = f"surveillance camera frame, {light}, {color}"
    return f"{extra} {base}".strip() if extra else base

def prune():
    total = collection.count()
    if total > MAX_FRAMES:
        old = collection.get(limit=total-MAX_FRAMES, include=["metadatas"])
        if old["ids"]:
            collection.delete(ids=old["ids"])

# ── Routes ────────────────────────────────────────────────────────
@app.get("/")
def root():
    return {"ok": True, "model": MODEL, "frames": collection.count()}

@app.get("/stats")
def stats():
    return {"total_frames": collection.count(), "model": MODEL, "collection": "nazar_frames"}

@app.post("/embed")
def embed_frame(req: EmbedReq):
    try:    raw = decode_b64(req.imageBase64)
    except: raise HTTPException(400, "Invalid image")
    desc = frame_description(raw, req.description)
    try:    vec = embed(desc)
    except Exception as e:
        raise HTTPException(500, f"Ollama error: {e}")
    fid = str(uuid.uuid4())
    collection.add(
        ids=[fid], embeddings=[vec], documents=[desc],
        metadatas=[{
            "timestamp": req.timestamp, "camera_id": req.cameraId,
            "description": req.description, "thumb": thumb(raw),
            "created_at": int(time.time()),
        }],
    )
    prune()
    return {"id": fid, "stored": True, "total": collection.count()}

@app.post("/search")
def search(req: SearchReq):
    if not req.query.strip():
        raise HTTPException(400, "Empty query")
    total = collection.count()
    if total == 0:
        return {"results": [], "query": req.query, "total_searched": 0}
    try:    qvec = embed(req.query)
    except Exception as e:
        raise HTTPException(500, f"Ollama error: {e}")
    where = {"camera_id": req.cameraId} if req.cameraId else None
    res = collection.query(
        query_embeddings=[qvec],
        n_results=min(req.topK, total),
        include=["metadatas", "distances", "documents"],
        where=where,
    )
    out = []
    for i, rid in enumerate(res["ids"][0]):
        m = res["metadatas"][0][i]
        out.append({
            "id": rid,
            "timestamp":   m.get("timestamp", ""),
            "cameraId":    m.get("camera_id", ""),
            "description": m.get("description", res["documents"][0][i]),
            "distance":    round(res["distances"][0][i], 4),
            "thumbBase64": m.get("thumb", ""),
        })
    return {"results": out, "query": req.query, "total_searched": total}

@app.delete("/clear")
def clear():
    global collection
    chroma.delete_collection("nazar_frames")
    collection = chroma.get_or_create_collection(
        name="nazar_frames", metadata={"hnsw:space": "cosine"})
    return {"cleared": True}

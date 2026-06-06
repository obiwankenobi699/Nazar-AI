"""
scripts/embedder.py  —  Nazar AI Local Embedding Server
FastAPI + ChromaDB + SigLIP embeddings

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
import chromadb, base64, io, time, uuid
from PIL import Image
import torch
from transformers import AutoModel, AutoProcessor

MODEL_NAME = "google/siglip-base-patch16-224"

model = AutoModel.from_pretrained(MODEL_NAME)
processor = AutoProcessor.from_pretrained(MODEL_NAME)

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

MAX_FRAMES = 2000

class EmbedReq(BaseModel):
    imageBase64: str
    timestamp:   str
    cameraId:    str = "cam-0"
    description: str = ""

class SearchReq(BaseModel):
    query:    str | None = None
    imageBase64: str | None = None
    topK:     int = 6
    cameraId: str | None = None

def decode_b64(s: str) -> bytes:
    return base64.b64decode(s.split(",", 1)[1] if "," in s else s)

def thumb(raw: bytes, size=(128, 72)) -> str:
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    img.thumbnail(size, Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=55)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()

def embed_image(image_b64: str) -> list[float]:
    image_data = base64.b64decode(image_b64.split(",", 1)[1] if "," in image_b64 else image_b64)
    image = Image.open(io.BytesIO(image_data)).convert("RGB")
    inputs = processor(images=image, return_tensors="pt")
    with torch.no_grad():
        embedding = model.get_image_features(**inputs)
    embedding = embedding / embedding.norm(dim=-1, keepdim=True)
    return embedding.squeeze().cpu().tolist()

def embed_text(text: str) -> list[float]:
    inputs = processor(text=[text], padding=True, return_tensors="pt")
    with torch.no_grad():
        embedding = model.get_text_features(**inputs)
    embedding = embedding / embedding.norm(dim=-1, keepdim=True)
    return embedding.squeeze().cpu().tolist()

import base64
import io
from PIL import Image
import numpy as np
from skimage.metrics import structural_similarity as ssim

def prune():
    total = collection.count()
    if total > MAX_FRAMES:
        old = collection.get(limit=total-MAX_FRAMES, include=["metadatas"])
        if old["ids"]:
            collection.delete(ids=old["ids"])

last_embedded_frame = None

def is_duplicate_frame(new_frame_b64: str, threshold: float = 0.95) -> bool:
    global last_embedded_frame
    if last_embedded_frame is None:
        return False

    def b64_to_np(b64_str):
        img_data = base64.b64decode(b64_str.split(",", 1)[1] if "," in b64_str else b64_str)
        img = Image.open(io.BytesIO(img_data)).convert("L")  # grayscale
        return np.array(img)

    new_img = b64_to_np(new_frame_b64)
    last_img = b64_to_np(last_embedded_frame)

    score = ssim(new_img, last_img)
    return score > threshold

def update_last_embedded_frame(frame_b64: str):
    global last_embedded_frame
    last_embedded_frame = frame_b64

@app.get("/")
def root():
    return {"ok": True, "model": MODEL_NAME, "frames": collection.count()}

@app.get("/stats")
def stats():
    return {"total_frames": collection.count(), "model": MODEL_NAME, "collection": "nazar_frames"}

@app.post("/embed")
def embed_frame(req: EmbedReq):
    try:
        raw = decode_b64(req.imageBase64)
    except:
        raise HTTPException(400, "Invalid image")
    desc = req.description or "No description"
    # Check for duplicate frame
    if is_duplicate_frame(req.imageBase64):
        return {"id": None, "stored": False, "reason": "Duplicate frame skipped", "total": collection.count()}
    try:
        vec = embed_image(req.imageBase64)
    except Exception as e:
        raise HTTPException(500, f"SigLIP error: {e}")
    fid = str(uuid.uuid4())
    collection.add(
        ids=[fid], embeddings=[vec], documents=[desc],
        metadatas=[{
            "timestamp": req.timestamp, "camera_id": req.cameraId,
            "description": req.description, "thumb": thumb(raw),
            "created_at": int(time.time()),
        }],
    )
    update_last_embedded_frame(req.imageBase64)
    prune()
    return {"id": fid, "stored": True, "total": collection.count()}

@app.post("/search")
def search(req: SearchReq):
    if not req.query and not req.imageBase64:
        raise HTTPException(400, "Provide either query or imageBase64")
    total = collection.count()
    if total == 0:
        print("Search: No frames in DB")
        return {"found": False, "message": "No relevant footage found.", "query": req.query, "total_searched": 0}
    try:
        if req.imageBase64:
            qvec = embed_image(req.imageBase64)
        else:
            qvec = embed_text(req.query)
    except Exception as e:
        print(f"Search embedding error: {e}")
        raise HTTPException(500, f"SigLIP error: {e}")
    where = {"camera_id": req.cameraId} if req.cameraId else None
    res = collection.query(
        query_embeddings=[qvec],
        n_results=min(req.topK, total),
        include=["metadatas", "distances", "documents"],
        where=where,
    )
    print(f"Search query: {req.query or '[image]'}")
    print(f"Results found: {len(res['ids'][0])}")
    print("Distances:", res["distances"][0])

    # Gap detection to find largest jump in distances
    distances = res["distances"][0]
    if len(distances) == 0:
        print("Search: No results found")
        return {"found": False, "message": "No relevant footage found.", "query": req.query, "total_searched": total}

    sorted_indices = sorted(range(len(distances)), key=lambda i: distances[i])
    sorted_distances = [distances[i] for i in sorted_indices]

    gap = 0
    gap_idx = len(sorted_distances)
    for i in range(1, len(sorted_distances)):
        diff = sorted_distances[i] - sorted_distances[i-1]
        if diff > gap:
            gap = diff
            gap_idx = i

    keep_indices = sorted_indices[:gap_idx]

    filtered = []
    for i in keep_indices:
        m = res["metadatas"][0][i]
        filtered.append({
            "id": res["ids"][0][i],
            "timestamp": m.get("timestamp", ""),
            "cameraId": m.get("camera_id", ""),
            "description": m.get("description", res["documents"][0][i]),
            "distance": round(distances[i], 4),
            "thumbBase64": m.get("thumb", ""),
        })

    if not filtered:
        print("Search: No results passed gap detection")
        return {"found": False, "message": "No relevant footage found.", "query": req.query, "total_searched": total}

    print(f"Search: {len(filtered)} results returned after gap detection")
    return {"found": True, "results": filtered, "query": req.query, "total_searched": total}

@app.delete("/clear")
def clear():
    global collection
    chroma.delete_collection("nazar_frames")
    collection = chroma.get_or_create_collection(
        name="nazar_frames", metadata={"hnsw:space": "cosine"})
    return {"cleared": True}
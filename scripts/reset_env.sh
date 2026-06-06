#!/usr/bin/env bash

set -e

echo "================================="
echo "NAZAR AI Environment Reset"
echo "================================="

echo "[1] Setting Python 3.10.18 locally"
pyenv local 3.10.18

echo "[2] Removing old venv"
rm -rf .venv

echo "[3] Creating new venv"
python -m venv .venv

echo "[4] Activating venv"
source .venv/bin/activate

echo "[5] Upgrading pip"
pip install --upgrade pip setuptools wheel

echo "[6] Installing requirements"
pip install -r requirements.txt

echo "[7] Testing imports"

python - << 'PYEOF'
import chromadb
import torch
import transformers
import fastapi
import PIL
import numpy

print("✓ ChromaDB")
print("✓ Torch")
print("✓ Transformers")
print("✓ FastAPI")
print("✓ Pillow")
print("✓ NumPy")

from transformers import AutoModel, AutoProcessor

MODEL = "google/siglip-base-patch16-224"

print("Downloading/loading SigLIP...")
AutoModel.from_pretrained(MODEL)
AutoProcessor.from_pretrained(MODEL)

print("✓ SigLIP Loaded Successfully")
PYEOF

echo ""
echo "================================="
echo "READY"
echo "================================="
echo ""
echo "Activate later with:"
echo "source .venv/bin/activate"

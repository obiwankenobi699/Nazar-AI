#!/usr/bin/env bash
# Start Nazar AI embedding server
# Run from project root: bash scripts/start-embedder.sh

cd "$(dirname "$0")"

echo "🔍 Nazar Embedder → http://localhost:8000"
echo "   Docs: http://localhost:8000/docs"

# Activate virtual environment
if [ -f .venv/bin/activate ]; then
  source .venv/bin/activate
else
  echo "Warning: Virtual environment not found at .venv/bin/activate"
fi

# Start FastAPI embedder server
uvicorn embedder:app --host 0.0.0.0 --port 8000 --reload

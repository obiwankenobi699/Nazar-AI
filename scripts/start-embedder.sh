#!/usr/bin/env bash
# Start Nazar AI embedding server with readiness checks and logging
# Run from project root: bash scripts/start-embedder.sh

cd "$(dirname "$0")"

# Function to check if Ollama is running
check_ollama() {
  if pgrep -x ollama &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Start Ollama if not running
if ! check_ollama; then
  echo "Starting Ollama..."
  ollama serve &> ollama.log &
  # Wait for Ollama to be ready (max 15 seconds)
  for i in {1..15}; do
    if check_ollama; then
      echo "Ollama started."
      break
    fi
    echo "Waiting for Ollama to start... ($i)"
    sleep 1
  done
  if ! check_ollama; then
    echo "Failed to start Ollama. Check ollama.log for details."
    exit 1
  fi
else
  echo "Ollama already running."
fi

echo "🔍 Nazar Embedder → http://localhost:8000"
echo "   Docs: http://localhost:8000/docs"

# Activate virtual environment
if [ -f .venv/bin/activate ]; then
  source .venv/bin/activate
else
  echo "Warning: Virtual environment not found at .venv/bin/activate"
fi

# Start FastAPI embedder server with logging
uvicorn embedder:app --host 0.0.0.0 --port 8000 --reload

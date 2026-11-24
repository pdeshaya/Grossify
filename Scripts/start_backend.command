#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$PROJECT_ROOT/Backend"
SOURCE="$BACKEND_DIR/grossify_backend.cpp"
EXECUTABLE="$BACKEND_DIR/grossify_backend"

if ! command -v clang++ >/dev/null 2>&1; then
    echo "Error: clang++ was not found. Install Apple Command Line Tools with: xcode-select --install" >&2
    exit 1
fi

if [[ ! -f "$SOURCE" ]]; then
    echo "Error: backend source not found: $SOURCE" >&2
    echo "Run this script from a Grossify_Desktop checkout that includes the Backend folder." >&2
    exit 1
fi

echo "Building Grossify backend..."
if ! clang++ -std=c++17 -Wall -Wextra "$SOURCE" -lsqlite3 -o "$EXECUTABLE"; then
    echo "Error: backend build failed. Check the compiler output above and confirm SQLite is available in the macOS Command Line Tools." >&2
    exit 1
fi

echo "Starting Grossify backend on port 8080. Press Control-C to stop."
cd "$BACKEND_DIR"
exec "$EXECUTABLE" 8080

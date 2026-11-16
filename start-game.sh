#!/bin/sh
# Start R Code Quest in your browser (macOS / Linux).
# Uses uv if installed (it fetches Python itself), otherwise python3.
cd "$(dirname "$0")" || exit 1

if command -v uv >/dev/null 2>&1; then
  RUN="uv run"
else
  RUN="python3"
fi

if [ ! -f vendor/webr/webr.mjs ]; then
  echo "First run: downloading webR and R packages for offline play..."
  $RUN setup_offline.py || exit 1
fi
exec $RUN serve.py "$@"

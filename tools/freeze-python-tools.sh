#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$ROOT/.venv"
OUTPUT="$ROOT/build/frozen"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "error: create $VENV before freezing tools" >&2
  exit 2
fi

mkdir -p "$OUTPUT"
echo "Freezing shared menu helper..."
"$VENV/bin/python" -m PyInstaller --noconfirm --clean --onefile \
  --name divoom-helper --distpath "$OUTPUT" --workpath "$ROOT/build/pyinstaller-work/divoom-helper" \
  --specpath "$ROOT/build/pyinstaller-spec" "$ROOT/tools/divoom_helper.py"

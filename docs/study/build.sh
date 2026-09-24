#!/usr/bin/env bash
# build.sh: render every docs/study/*.html to a PDF next to it, using headless Chrome (no Python needed).
# Run from Git Bash on Windows:  bash docs/study/build.sh
set -euo pipefail
CHROME="/c/Program Files/Google/Chrome/Application/chrome.exe"
cd "$(dirname "$0")"
DIR_WIN="$(pwd -W)"                                 # e.g. G:/k8S-with-claude/docs/study
for f in *.html; do
  pdf="${f%.html}.pdf"
  "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer \
    --print-to-pdf="$DIR_WIN/$pdf" "file:///$DIR_WIN/$f" 2>/dev/null
  echo "built $pdf"
done

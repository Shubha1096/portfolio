#!/usr/bin/env bash
# Converts the project documents listed in docs/sources.txt into PDFs.
#
# For each document it downloads the latest version from Google Drive and
# compares it with the fingerprint saved last time (docs/.hashes/<name>.sha256).
# Only documents that actually changed are converted, so a run with no edits
# finishes in seconds and commits nothing.
#
# Usage: scripts/refresh-docs.sh   (run from the repository root)
# Writes "changed=true|false" and "failed=true|false" to $GITHUB_OUTPUT if set.

set -uo pipefail

SOURCES=docs/sources.txt
HASHES=docs/.hashes
WORK=$(mktemp -d)
mkdir -p "$HASHES"

changed=false
failed=false
soffice_ready=false

ensure_soffice() {
  $soffice_ready && return 0
  if ! command -v soffice >/dev/null 2>&1; then
    echo "Installing LibreOffice (only needed when a document changed)…"
    sudo apt-get update -qq >/dev/null
    sudo apt-get install -y -qq --no-install-recommends libreoffice-writer-nogui \
      fonts-liberation fonts-crosextra-carlito fonts-crosextra-caladea >/dev/null
  fi
  soffice_ready=true
}

while read -r ID NAME _; do
  [[ -z "${ID:-}" || "$ID" == \#* ]] && continue
  echo "== $NAME ($ID)"
  src="$WORK/$NAME"
  out="docs/$NAME.pdf"

  # 1) Uploaded Word file (.docx): direct download from Drive
  kind=""
  if curl -fsSL --retry 3 --retry-delay 5 \
       "https://drive.google.com/uc?export=download&id=${ID}" -o "$src.bin" \
     && [ "$(head -c 2 "$src.bin")" = "PK" ]; then
    kind=docx; mv "$src.bin" "$src.docx"
  # 2) Native Google Doc: Google exports the PDF itself
  elif curl -fsSL --retry 3 --retry-delay 5 \
       "https://docs.google.com/document/d/${ID}/export?format=pdf" -o "$src.pdf" \
     && [ "$(head -c 4 "$src.pdf")" = "%PDF" ]; then
    kind=gdoc
  else
    echo "::warning::Could not download $NAME. Is it shared as 'Anyone with the link can view'?"
    failed=true; continue
  fi

  if [ "$kind" = docx ]; then
    new_hash=$(sha256sum "$src.docx" | cut -d' ' -f1)
  else
    # Exported PDFs embed timestamps, so compare their text instead
    new_hash=$(pdftotext -layout "$src.pdf" - 2>/dev/null | sha256sum | cut -d' ' -f1)
  fi
  old_hash=$(cat "$HASHES/$NAME.sha256" 2>/dev/null || true)

  if [ "$new_hash" = "$old_hash" ] && [ -f "$out" ]; then
    echo "$NAME unchanged."
    continue
  fi

  if [ "$kind" = docx ]; then
    ensure_soffice
    if ! soffice --headless --convert-to pdf --outdir "$WORK" "$src.docx" >/dev/null 2>&1 \
       || [ ! -s "$src.pdf" ]; then
      echo "::warning::LibreOffice could not convert $NAME"; failed=true; continue
    fi
  fi

  mv "$src.pdf" "$out"
  echo "$new_hash" > "$HASHES/$NAME.sha256"
  changed=true
  echo "$NAME updated → $out"
done < "$SOURCES"

rm -rf "$WORK"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "changed=$changed" >> "$GITHUB_OUTPUT"
  echo "failed=$failed" >> "$GITHUB_OUTPUT"
fi
echo "changed=$changed failed=$failed"

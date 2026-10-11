#!/bin/sh
# Sends an audio file through the transcribe function. Usage: test.sh <audio file> [prompt]
set -e
TOKEN=$(cat "$(dirname "$0")/../.secret.local")
curl -sS -X POST https://asia-southeast1-speechpoc-whisper.cloudfunctions.net/transcribe \
  -H "Authorization: Bearer $TOKEN" -F "audio=@$1" -F "prompt=${2:-}"
echo

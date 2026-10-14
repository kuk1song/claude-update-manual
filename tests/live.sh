#!/usr/bin/env bash
# Read-only check against the real release bucket: verifies the newest
# manifest's GPG signature with the pinned Anthropic key and, on macOS, the
# code signature of the installed binary. Installs and changes nothing.
set -euo pipefail
REPO="https://downloads.claude.ai/claude-code-releases"
FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
REQ='anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW"'
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
command -v gpgv >/dev/null || { echo "gpgv not found" >&2; exit 1; }
command -v gpg >/dev/null || { echo "gpg not found" >&2; exit 1; }

v="$(curl -fsSL --proto =https "$REPO/latest")"
echo "latest: $v"
curl -fsSL --proto =https "$REPO/$v/manifest.json" -o "$T/m.json"
curl -fsSL --proto =https "$REPO/$v/manifest.json.sig" -o "$T/m.json.sig"
curl -fsSL --proto =https https://downloads.claude.ai/keys/claude-code.asc -o "$T/key.asc"
gpg --dearmor <"$T/key.asc" >"$T/key.gpg" 2>/dev/null
if gpgv --keyring "$T/key.gpg" --status-fd 1 "$T/m.json.sig" "$T/m.json" 2>/dev/null |
   awk -v f="$FPR" '$2 == "VALIDSIG" && ($3 == f || $NF == f) { ok = 1 } END { exit !ok }'; then
  echo "manifest $v: signature OK, key $FPR"
else
  echo "manifest $v: signature check FAILED" >&2
  exit 1
fi

if [ "$(uname -s)" = Darwin ] && [ -L "$HOME/.local/bin/claude" ]; then
  b="$(readlink "$HOME/.local/bin/claude")"
  if codesign --verify --strict -R="$REQ" "$b"; then
    echo "installed $(basename "$b"): Anthropic code signature OK"
  else
    echo "installed $(basename "$b"): code signature check FAILED" >&2
    exit 1
  fi
fi

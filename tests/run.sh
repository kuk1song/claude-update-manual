#!/usr/bin/env bash
# End-to-end tests against a local mock release server. Nothing outside a
# temporary directory is touched: HOME and XDG_CACHE_HOME point into it, and
# the tool under test is a copy whose constants point at the mock server.
# The checks are strings run by eval, so single quotes are intended.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL_SRC="$HERE/../claude-update-manual"
T="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap cleanup EXIT

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/     /'; fi; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${OUT:-}"; fi; }

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLAT=darwin-arm64 ;;
  Darwin-x86_64) PLAT=darwin-x64 ;;
  Linux-aarch64) PLAT=linux-arm64 ;;
  Linux-x86_64) PLAT=linux-x64 ;;
  *) echo "unsupported test platform"; exit 1 ;;
esac
if [ "${PLAT%%-*}" = linux ] && ldd /bin/ls 2>&1 | grep -q musl; then PLAT="$PLAT-musl"; fi

ROOT="$T/srv"
mkdir -p "$ROOT/keys"
USE_GPG=0
KEY="0000000000000000000000000000000000000000"
if command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1; then
  USE_GPG=1
  export GNUPGHOME="$T/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-gen-key "Test Release <test@example.invalid>" ed25519 sign never 2>/dev/null
  gpg --batch --quiet --passphrase '' --quick-gen-key "Old Key <old@example.invalid>" ed25519 sign never 2>/dev/null
  KEY="$(gpg --with-colons --list-keys test@example.invalid 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
  gpg --armor --export test@example.invalid >"$ROOT/keys/claude-code.asc"
fi

mkbin() { # path printed-version
  { printf '#!/bin/sh\necho "%s (Claude Code)"\nexit 0\n' "$2"
    head -c 200000 /dev/urandom | od -An -tx1 | sed 's/^/# /'; } >"$1"
  chmod 755 "$1"
}
sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
manifest() { # out version checksum size
  printf '{"version":"%s","platforms":{"%s":{"binary":"claude","checksum":"%s","size":%s}}}\n' \
    "$2" "$PLAT" "$3" "$4" >"$1"
}
sign() { # file [bad]
  [ "$USE_GPG" = 1 ] || return 0
  if [ "${2:-}" = bad ]; then
    echo tampered | gpg --batch --yes --quiet -u test@example.invalid --detach-sign -o "$1.sig"
  else
    gpg --batch --yes --quiet -u test@example.invalid --detach-sign -o "$1.sig" "$1"
  fi
}
release() { # version [printed-version] [mode: ok|badsha|wrongver|nosig|badsig|zstbadsig]
  local v="$1" printed="${2:-$1}" mode="${3:-ok}" d="$ROOT/$1" s z mv="$1"
  [ -n "$printed" ] || printed="$v"
  mkdir -p "$d/$PLAT"
  mkbin "$d/$PLAT/claude" "$printed"
  zstd -q -f "$d/$PLAT/claude" -o "$d/$PLAT/claude.zst"
  s="$(sha "$d/$PLAT/claude")"
  z="$(sha "$d/$PLAT/claude.zst")"
  if [ "$mode" = badsha ]; then s="$(printf '%064d' 0)"; z="$s"; fi
  if [ "$mode" = wrongver ]; then mv="2.1.301"; fi
  manifest "$d/manifest.json" "$mv" "$s" "$(wc -c <"$d/$PLAT/claude" | tr -d ' ')"
  manifest "$d/manifest.zst.json" "$mv" "$z" "$(wc -c <"$d/$PLAT/claude.zst" | tr -d ' ')"
  case "$mode" in
    nosig) ;;
    badsig) sign "$d/manifest.json" bad; sign "$d/manifest.zst.json" ;;
    zstbadsig) sign "$d/manifest.json"; sign "$d/manifest.zst.json" bad ;;
    *) sign "$d/manifest.json"; sign "$d/manifest.zst.json" ;;
  esac
}

release 2.1.299
release 2.1.301
release 2.1.302 "" badsha
release 2.1.303 "" wrongver
release 2.1.304 9.9.9
release 2.1.305
release 2.1.307 "" badsig
release 2.1.308 "" nosig
release 2.1.309 "" zstbadsig
release 2.1.310
release 2.1.311
printf '2.1.301\n' >"$ROOT/latest"
printf '2.1.299\n' >"$ROOT/stable"

LOG="$T/requests.log"
: >"$LOG"
python3 "$HERE/mock_server.py" "$ROOT" "$T/port" "$LOG" \
  "/2.1.301/$PLAT/claude.zst,/2.1.305/$PLAT/claude" "/2.1.310/$PLAT/claude.zst" 2>"$T/server.err" &
SERVER_PID=$!
for _ in $(seq 1 300); do
  [ -s "$T/port" ] && break
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
if [ ! -s "$T/port" ]; then
  echo "mock server did not start:"; cat "$T/server.err"; exit 1
fi
PORT="$(cat "$T/port")"

# The copy under test: same code, constants pointed at the mock server.
TOOL="$T/cum"
sed -e "s|^REPO=.*|REPO=\"http://127.0.0.1:$PORT\"|" \
    -e "s|^KEY_URL=.*|KEY_URL=\"http://127.0.0.1:$PORT/keys/claude-code.asc\"|" \
    -e "s|^KEY_FPR=.*|KEY_FPR=\"$KEY\"|" \
    -e 's|^PROTO=.*|PROTO="=http"|' \
    -e 's|^CHECK_CODESIGN=.*|CHECK_CODESIGN=0|' \
    -e 's|^STALL_SECS=.*|STALL_SECS=2|' "$TOOL_SRC" >"$TOOL"
chmod 755 "$TOOL"
[ "$(grep -cE '^(REPO|KEY_URL|KEY_FPR|PROTO|CHECK_CODESIGN|STALL_SECS)=' "$TOOL")" = 6 ] || { echo "constant rewrite failed"; exit 1; }
grep -q "127.0.0.1:$PORT" "$TOOL" || { echo "constant rewrite failed"; exit 1; }

export HOME="$T/home" XDG_CACHE_HOME="$T/cache"
unset DISABLE_UPDATES || true
C="$XDG_CACHE_HOME/claude-update-manual"
V="$HOME/.local/share/claude/versions"
L="$HOME/.local/bin/claude"
mkdir -p "$V" "$(dirname "$L")" "$HOME/.claude"
mkbin "$V/2.1.300" 2.1.300
ln -s "$V/2.1.300" "$L"
target() { basename "$(readlink "$L")"; }
run() { OUT="$("$TOOL" "$@" 2>&1)"; RC=$?; }

set +e
check "shipped script has no test overrides" '! grep -q "CUM_TEST" "$TOOL_SRC"'
run --version;  check "--version" '[ $RC = 0 ] && [[ "$OUT" == "claude-update-manual "* ]]'
run --help;     check "--help" '[ $RC = 0 ] && [[ "$OUT" == *"usage:"* ]]'
run --bogus;    check "unknown flag is rejected" '[ $RC = 2 ]'
run --check;    check "--check" '[ $RC = 0 ] && [[ "$OUT" == *"installed : 2.1.300"* ]] && [[ "$OUT" == *"latest    : 2.1.301"* ]]'

run latest
check "update resumes after a dropped connection" '[ $RC = 0 ] && [[ "$OUT" == *"resuming"* ]] && [ "$(target)" = 2.1.301 ]'
check "resume used an HTTP range request" 'grep -q "GET /2.1.301/$PLAT/claude.zst bytes=[1-9]" "$LOG"'
check "previous version recorded" '[ "$(cat "$C/previous")" = 2.1.300 ]'
check "work and staging files cleaned up" '[ ! -d "$C/2.1.301-$PLAT" ] && [ -z "$(find "$V" -name ".cum-*")" ]'
check "lock released" '[ ! -e "$C/lock" ] && [ ! -L "$C/lock" ]'
if [ "$USE_GPG" = 1 ]; then
  check "manifest signature verified" '[[ "$OUT" == *"manifest signature: OK"* ]]'
fi

run latest;     check "already current" '[ $RC = 0 ] && [[ "$OUT" == *"already on 2.1.301"* ]]'
run --rollback; check "rollback to the previous version" '[ $RC = 0 ] && [ "$(target)" = 2.1.300 ]'
run 2.1.301;    check "reactivate an installed version without downloading" '[ $RC = 0 ] && [[ "$OUT" == *"already installed"* ]] && [ "$(target)" = 2.1.301 ]'
run stable;     check "stable channel resolves and installs" '[ $RC = 0 ] && [ "$(target)" = 2.1.299 ]'

run 2.1.310
check "stalled download resumes without losing data" '[ $RC = 0 ] && [ "$(target)" = 2.1.310 ] && grep -q "GET /2.1.310/$PLAT/claude.zst bytes=[1-9]" "$LOG" && [ "$(grep -c "GET /2.1.310/$PLAT/claude.zst" "$LOG")" = 2 ]'
run 2.1.302
check "checksum mismatch is refused" '[ $RC != 0 ] && [ "$(target)" = 2.1.310 ] && [ ! -e "$V/2.1.302" ]'
check "bad partial download is removed" '[ -z "$(find "$XDG_CACHE_HOME" -name "claude.dl" 2>/dev/null)" ]'
run 2.1.303;    check "manifest for another version is refused" '[ $RC != 0 ] && [[ "$OUT" == *"manifest is for"* ]] && [ "$(target)" = 2.1.310 ]'
run 2.1.304;    check "failed smoke test changes nothing" '[ $RC != 0 ] && [[ "$OUT" == *"smoke test"* ]] && [ ! -e "$V/2.1.304" ] && [ "$(target)" = 2.1.310 ] && [ -z "$(find "$V" -name ".cum-*")" ]'
run --no-zst 2.1.305
check "uncompressed path with a dropped connection" '[ $RC = 0 ] && [[ "$OUT" == *"resuming"* ]] && [[ "$OUT" != *"compressed and decompressed"* ]] && [ "$(target)" = 2.1.305 ]'
run ../../etc;  check "path-like target is rejected" '[ $RC != 0 ] && [[ "$OUT" == *"not a channel or version"* ]]'
run "$(printf '2.1.301\nx')"; check "multi-line target is rejected" '[ $RC != 0 ] && [[ "$OUT" == *"not a channel or version"* ]]'
if [ "$USE_GPG" = 1 ]; then
  run 2.1.307;  check "bad signature is refused" '[ $RC != 0 ] && [[ "$OUT" == *"signature check failed"* ]] && [ ! -e "$V/2.1.307" ]'
  run 2.1.308;  check "missing signature is refused" '[ $RC != 0 ] && [ ! -e "$V/2.1.308" ]'
  run 2.1.309;  check "bad compressed-manifest signature falls back to the full download" '[ $RC = 0 ] && [[ "$OUT" == *"compressed manifest signature not valid"* ]] && [ "$(target)" = 2.1.309 ]'
  gpg --export old@example.invalid >"$C/release-key-$KEY.gpg"
  run 2.1.311;  check "a stale cached key is refreshed" '[ $RC = 0 ] && [[ "$OUT" == *"manifest signature: OK"* ]] && [ "$(target)" = 2.1.311 ]'
fi

DISABLE_UPDATES=1 run 2.1.301
check "DISABLE_UPDATES blocks updates" '[ $RC != 0 ] && [[ "$OUT" == *"disabled"* ]]'
DISABLE_UPDATES=1 run --rollback
check "DISABLE_UPDATES blocks rollback" '[ $RC != 0 ] && [[ "$OUT" == *"disabled"* ]]'
printf '{"minimumVersion":"2.1.400"}\n' >"$HOME/.claude/settings.json"
run 2.1.301;    check "minimumVersion is respected" '[ $RC != 0 ] && [[ "$OUT" == *"policy"* ]]'
printf '{"env":{"DISABLE_UPDATES":"1"}}\n' >"$HOME/.claude/settings.json"
run 2.1.301;    check "DISABLE_UPDATES in settings.json is respected" '[ $RC != 0 ] && [[ "$OUT" == *"disabled"* ]]'
run --hook;     check "hook stays silent when updates are disabled" '[ $RC = 0 ] && [ -z "$OUT" ]'
printf '[1]\n' >"$HOME/.claude/settings.json"
DISABLE_UPDATES=1 run 2.1.301
check "unreadable settings stop the update" '[ $RC != 0 ] && [[ "$OUT" == *"cannot read the update policy"* ]]'
printf '{"env":null,"minimumVersion":"9.0.0"}\n' >"$HOME/.claude/settings.json"
run 2.1.301;    check "env null still applies minimumVersion" '[ $RC != 0 ] && [[ "$OUT" == *"policy"* ]]'
printf '{"minimumVersion":7}\n' >"$HOME/.claude/settings.json"
run 2.1.301;    check "malformed minimumVersion stops the update" '[ $RC != 0 ] && [[ "$OUT" == *"not a version"* ]]'
rm -f "$HOME/.claude/settings.json"

printf '2.1.399\n' >"$ROOT/latest"
rm -f "$C/latest.txt"
run --hook
check "hook announces a newer version as valid JSON" '[ $RC = 0 ] && printf "%s" "$OUT" | python3 -c "import json,sys; m=json.load(sys.stdin)[\"systemMessage\"]; assert \"2.1.399\" in m"'
N1="$(grep -c "GET /latest" "$LOG")"
run --hook
check "hook checks the network at most once per 24 hours" '[ "$(grep -c "GET /latest" "$LOG")" = "$N1" ] && [[ "$OUT" == *"2.1.399"* ]]'
printf '<html>oops</html>\n' >"$ROOT/latest"
rm -f "$C/latest.txt"
run --hook
check "hook ignores a garbage answer" '[ $RC = 0 ] && [ -z "$OUT" ] && [ ! -e "$C/latest.txt" ]'
printf '2.1.398\n' >"$ROOT/stable"
printf '{"autoUpdatesChannel":"stable"}\n' >"$HOME/.claude/settings.json"
run --hook
check "hook follows autoUpdatesChannel" '[ $RC = 0 ] && [[ "$OUT" == *"2.1.398"* ]] && [[ "$OUT" == *"claude-update-manual stable"* ]]'
rm -f "$HOME/.claude/settings.json"
printf '2.1.301\n' >"$ROOT/latest"

sleep 30 &
SLEEPER=$!
mkdir -p "$C"
ln -s "$SLEEPER" "$C/lock"
run 2.1.301;    check "concurrent run is refused" '[ $RC != 0 ] && [[ "$OUT" == *"in progress"* ]]'
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
run 2.1.301;    check "lock from a dead process is recovered" '[ $RC = 0 ] && [ "$(target)" = 2.1.301 ]'
mkdir "$C/lock"
run 2.1.305;    check "an old directory-style lock is recovered" '[ $RC = 0 ] && [ "$(target)" = 2.1.305 ]'

mkbin "$T/dev-build" 9.9.9
ln -sfn "$T/dev-build" "$L"
run 2.1.301;    check "symlink to a build outside versions/ is left alone" '[ $RC != 0 ] && [[ "$OUT" == *"custom launcher"* ]] && [ "$(readlink "$L")" = "$T/dev-build" ]'
rm "$L"; printf '#!/bin/sh\n' >"$L"
run 2.1.301;    check "script launcher is left alone" '[ $RC != 0 ] && [[ "$OUT" == *"custom launcher"* ]] && [ ! -L "$L" ]'
set -e

echo
echo "$PASS passed, $FAIL failed (signature tests: $([ "$USE_GPG" = 1 ] && echo on || echo 'off, gpg not found'))"
[ "$FAIL" = 0 ]

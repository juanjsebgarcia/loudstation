#!/usr/bin/env bash
# Command-line tests for loudstation, run by `make test` with the built CLI and app bundle.
# Nothing here probes, fixes or cycles a display: only argument handling, help, version,
# `list` and localised error messages. State and log go to the temporary folder `make test`
# provides.
set -u

binary="$1"
app="$2"

if [ -z "${LOUDSTATION_STATE_DIR:-}" ] || [ -z "${LOUDSTATION_LOG:-}" ]; then
  echo "Run through \`make test\`, which points LOUDSTATION_STATE_DIR and LOUDSTATION_LOG at a temporary folder." >&2
  exit 2
fi

# English expectations must not depend on the Mac's language or on an installed app bundle,
# so the English sections use the test fixture (English except for two overridden keys).
fixture="$(cd "$(dirname "$0")" && pwd)/Fixtures/Strings.bundle"
export LOUDSTATION_STRINGS_BUNDLE="$fixture"
passed=0
failed=0

# expect <exit code> <extended regex the output must match, or -> <arguments...>
expect() {
  local want="$1" pattern="$2"
  shift 2
  local output code
  output=$("$binary" "$@" 2>&1)
  code=$?
  if [ "$code" = "$want" ] && { [ "$pattern" = "-" ] || grep -qE -- "$pattern" <<<"$output"; }; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: loudstation $* -> exit $code (wanted $want, output matching '$pattern')"
    sed 's/^/    /' <<<"$output" | head -5
  fi
}

echo "- Help and version"
expect 0 '^loudstation [0-9]+\.[0-9]+\.[0-9]+$' --version
expect 0 'Exit codes' --help
expect 0 'Exit codes' -h

echo "- Bad arguments are refused before anything is checked or switched off"
expect 2 'Unknown command' prob
expect 2 'Unknown option' --hodl
expect 2 'needs a value' --hold
expect 2 'from 0.5 to 30' --hold 1e9 fix
expect 2 'from 0.5 to 30' --hold inf fix
expect 2 'from 0.5 to 60' --seconds 0.1 fix
expect 2 'from 0 to 60' --settle -1 fix
expect 2 'needs a value' --uid
expect 2 'needs a value' --uid --hold 3
expect 2 'Only one command' fix relink
expect 2 'No audio output with ID' --uid NOPE fix
expect 2 'loudstation --help' prob

echo "- Options may come before the command, and Foundation's own arguments are accepted"
expect 0 'Audio outputs' --hold 5 list
expect 0 'Audio outputs' list -AppleLanguages '(en)'

echo "- Messages follow the language, using the app bundle's translations"
export LOUDSTATION_STRINGS_BUNDLE="$app"
expect 2 'muss eine Zahl' --hold 99 fix -AppleLanguages '(de)'
expect 2 '0,5' --hold 99 fix -AppleLanguages '(de)'
expect 2 'doit être' --hold 99 fix -AppleLanguages '(fr)'
expect 2 '[^ -~]' --hold 99 fix -AppleLanguages '(ja)'
expect 2 'Unknown command' prob -AppleLanguages '(xx)'
export LOUDSTATION_STRINGS_BUNDLE="$fixture"

echo "cli: $passed passed, $failed failed"
[ "$failed" = 0 ]

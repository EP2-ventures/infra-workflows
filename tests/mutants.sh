#!/usr/bin/env bash
# Does env-pin-preservation.sh actually DISCRIMINATE?
#
# That suite is 24 green assertions about a shell block. Green is not evidence until
# you can name the input that would turn each assertion red and show it doing so —
# a suite that cannot fail is a decoration that looks exactly like a gate.
#
# So: break the workflow on purpose, four ways, and require the suite to catch each
# one. Every mutant here is
#   * NON-VACUOUS  — the edit is asserted to have changed the file, so a mutant that
#                    silently failed to apply can never be counted as "killed";
#   * ATTRIBUTABLE — the kill must show up as a named failure of the case that is
#                    supposed to own it, not merely as "the suite went red". A red
#                    for the wrong reason is not a kill.
# And the run opens with a positive control: the UNMUTATED tree must pass, or every
# "kill" below is just a broken harness.
#
# Cheap to run (seconds, no network, no docker), which is why CI runs it too.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="tests/env-pin-preservation.sh"
WF_REL=".github/workflows/deploy-reusable.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { echo "  ✔ $1"; }
bad() { echo "  ✘ $1"; fail=1; }

if ! sed --version >/dev/null 2>&1; then
  echo "SKIPPED: needs GNU sed, same as the suite it exercises."
  exit 2
fi

# Replace exactly one line of the workflow, matched on its content with the line
# ending stripped — the file has CRLF endings and they are preserved. Exits non-zero
# if the target line is not found EXACTLY once, so a mutant can never quietly become
# a no-op when the workflow moves.
mutate() { # $1 = tree  $2 = old line (stripped)  $3 = new line (stripped, "" deletes)
  python3 - "$1/$WF_REL" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, newline='') as f:
    src = f.read()
lines = src.splitlines(keepends=True)
hits = [i for i, l in enumerate(lines) if l.rstrip('\r\n') == old]
if len(hits) != 1:
    sys.exit(f"VACUOUS MUTANT: target line found {len(hits)} times, expected 1:\n  {old}")
i = hits[0]
end = lines[i][len(lines[i].rstrip('\r\n')):]
lines[i:i+1] = [] if new == "" else [new + end]
out = ''.join(lines)
if out == src:
    sys.exit("VACUOUS MUTANT: the edit changed nothing.")
with open(path, 'w', newline='') as f:
    f.write(out)
PY
}

run_mutant() { # $1 = id  $2 = why  $3 = old line  $4 = new line  $5 = expected failure substring
  local id="$1" why="$2" old="$3" new="$4" want="$5"
  local dir="$TMP/$id"
  echo "$id — $why"
  rm -rf "$dir"; mkdir -p "$dir"
  ( cd "$ROOT" && tar cf - .github "$SUITE" ) | ( cd "$dir" && tar xf - )
  if ! mutate "$dir" "$old" "$new"; then
    bad "$id could not be applied — it measured nothing"
    return
  fi
  local out; out="$( cd "$dir" && bash "$SUITE" 2>&1 )"; local rc=$?
  if [ "$rc" = "0" ]; then
    bad "$id SURVIVED — the suite passed against a workflow that is broken. It is not measuring this."
    return
  fi
  if printf '%s' "$out" | grep -qF "$want"; then
    ok "killed, and by the right assertion (exit $rc) — \"$want\""
  else
    bad "$id went red but NOT for its own reason (exit $rc). A red for the wrong reason is not a kill. Got:"
    printf '%s\n' "$out" | grep -E '✘|FAILED' | sed 's/^/        /'
  fi
}

# ── positive control ────────────────────────────────────────────────────────────
echo "0. positive control — the unmutated tree must PASS"
if ( cd "$ROOT" && bash "$SUITE" >/dev/null 2>&1 ); then
  ok "it does, so a red below is the mutant and not the harness"
else
  echo "  ✘ the suite is ALREADY failing on a clean tree. Every 'kill' below would be"
  echo "     unattributable. Fix that first."
  exit 1
fi

# ── mutants ─────────────────────────────────────────────────────────────────────
# M1 was first written as DELETING the `[ -f .env ]` guard, and the suite could not
# kill it — correctly, because the grep below it also ends `|| true`, so either one
# alone survives a bare host and removing the guard changes no behaviour. That is an
# equivalent mutant, not a hole; the note stays because "we tried the obvious mutant
# and it was vacuous" is the finding, and without it someone re-adds it every year.
# The real defect on that path is the guard returning NON-ZERO — under the block's
# `set -e` that aborts a first deploy onto a new host.
run_mutant "M1" "make preserve_pins' bare-host guard return non-zero → a first deploy aborts" \
  '              [ -f .env ] || return 0' \
  '              [ -f .env ] || return 1' \
  "EXTRACTED BLOCK FAILED TO EXECUTE"

run_mutant "M2" "stop mapping the hyphen in SVC_TAG_VAR → a hyphenated service stops matching its own pin" \
  '            SVC_TAG_VAR="$(echo "${SERVICE}" | tr '"'"'[:lower:]-'"'"' '"'"'[:upper:]_'"'"')_IMAGE_TAG"' \
  '            SVC_TAG_VAR="$(echo "${SERVICE}" | tr '"'"'[:lower:]'"'"' '"'"'[:upper:]'"'"')_IMAGE_TAG"' \
  "the stale hyphenated pin was carried forward"

run_mutant "M3" "stop deleting the dump's copy of a carried key → the result depends on parser order again" \
  '                sed -i "/^${key}=/d" "$1"' \
  '                :' \
  "the result depends on parser order"

run_mutant "M4" "make the no-Doppler branch replace .env instead of amending it" \
  '              [ -f .env ] || : > .env' \
  '              : > .env' \
  "the no-Doppler branch dropped ADMIN_IMAGE_TAG"

echo
[ "$fail" = "0" ] && echo "PASS — the suite discriminates on all four" || echo "FAIL"
exit "$fail"

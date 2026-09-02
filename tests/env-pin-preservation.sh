#!/usr/bin/env bash
# Does a rollback survive the OTHER service's next deploy?
#
# Regression test for the defect measured on privilege-gardens' live host
# 2026-08-20: `/opt/privilege-gardens/.env` held `ADMIN_IMAGE_TAG` and ZERO
# `LANDING_IMAGE_TAG` lines, and `docker compose config` resolved landing to
# `:latest` while its container was still on `snapshot-production-77-fb75ad0`.
# Cause: `deploy-reusable.yml` regenerated .env from Doppler and appended only the
# DEPLOYING service's pin, so exactly one service was ever pinned — whichever
# deployed last. Rolling A back and then deploying B left A due to jump forward to
# `latest` on the next recreate.
#
# ⚠️ THE CODE UNDER TEST IS EXTRACTED FROM THE WORKFLOW AT RUN TIME, not copied.
# A copy would be free to pass while the workflow drifts away from it, which is the
# whole failure mode a test like this is supposed to catch. If the markers below
# stop matching, this script FAILS rather than silently testing nothing.
set -uo pipefail

# The workflow runs on a Linux host, and its `sed -i` is GNU's. BSD sed (macOS)
# reads the next argument as the backup suffix and errors, which would print four
# red assertions that are about the platform, not about the code. Refuse to run
# instead: "I could not measure this" is a different answer from "this is wrong",
# and exit 2 keeps them different.
if ! sed --version >/dev/null 2>&1; then
  echo "SKIPPED: this test needs GNU sed (the deploy host's), and this is BSD sed."
  echo "Run it the way CI does:  docker run --rm -v \"\$PWD:/w\" -w /w debian:stable-slim bash tests/env-pin-preservation.sh"
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/deploy-reusable.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { echo "  ✔ $1"; }
bad() { echo "  ✘ $1"; fail=1; }

# ── extract ─────────────────────────────────────────────────────────────────────
# From the `preserve_pins()` definition through the end of the DOPPLER_TOKEN
# if/else, dedented. `${{ inputs.image_tag }}` becomes the shell var the harness
# sets, which is the only substitution made.
# `tr -d '\r'` FIRST: this workflow file has CRLF line endings, and without the
# strip the extractor's `/^ *fi *$/` never matches (the line ends `fi\r`), so it
# runs past the block and emits shell that dies on `$'{\r'`. Measured — and the
# harness happily printed three green assertions while the block had not executed
# at all, which is why the run-check below exists.
tr -d '\r' < "$WF" | awk '
  /^ *preserve_pins\(\) \{/ { on=1 }
  on { print }
  on && /^ *fi *$/ { exit }
' | sed -e 's/^            //' -e 's/\${{ inputs\.image_tag }}/${TAG}/g' > "$TMP/block.sh"

if ! grep -q 'preserve_pins .env.tmp' "$TMP/block.sh"; then
  echo "EXTRACTION FAILED: could not find the .env-writing block in $WF."
  echo "This test measured NOTHING. Fix the markers rather than deleting the test."
  exit 2
fi

# SVC_TAG_VAR is derived ABOVE the extracted block, and the whole of preserve_pins
# turns on comparing each key against it. The harness used to re-type that `tr` line
# itself — i.e. case 8 would have been grading the harness's copy, free to agree with
# itself while the workflow drifted. Extract that line too, for the same reason the
# block is extracted.
tr -d '\r' < "$WF" | grep -E '^ *SVC_TAG_VAR="\$\(echo ' | sed 's/^ *//' > "$TMP/svcvar.sh"
if [ ! -s "$TMP/svcvar.sh" ] || [ "$(wc -l < "$TMP/svcvar.sh")" != "1" ]; then
  echo "EXTRACTION FAILED: expected exactly one SVC_TAG_VAR assignment in $WF, got $(wc -l < "$TMP/svcvar.sh")."
  echo "This test measured NOTHING. Fix the markers rather than deleting the test."
  exit 2
fi

echo "Extracted $(wc -l < "$TMP/block.sh") lines of the real workflow script,"
echo "plus its own SVC_TAG_VAR derivation: $(cat "$TMP/svcvar.sh")"
echo

cat > "$TMP/doppler" <<'STUB'
#!/bin/sh
# Stands in for `doppler secrets download --format env --no-file`. The point of the
# test is what happens to the pins AROUND the dump, so the dump itself is a fixture.
# DOPPLER_EXTRA lets a case put extra lines in the dump — used by case 9, where the
# question is whether a pin coming FROM Doppler can overwrite the host's rollback.
printf 'NODE_ENV=production\nSOME_SECRET=xxx\n'
[ -n "${DOPPLER_EXTRA:-}" ] && printf '%s\n' "$DOPPLER_EXTRA"
# Explicit: the guard above exits 1 when DOPPLER_EXTRA is empty, and the caller runs
# under `set -e` with the dump redirected into .env.tmp. A non-zero stub would abort
# the block and every assertion after it would be about the PREVIOUS .env.
exit 0
STUB
chmod +x "$TMP/doppler"
export PATH="$TMP:$PATH"

run_deploy() {  # $1 = service   $2 = tag   [$3 = DOPPLER_TOKEN, "" for the no-Doppler branch]
  SERVICE="$1"; TAG="$2"
  . "$TMP/svcvar.sh"          # the workflow's own derivation, not a copy of it
  DOPPLER_TOKEN="${3-stub}"
  export SERVICE TAG SVC_TAG_VAR DOPPLER_TOKEN
  export DOPPLER_EXTRA="${DOPPLER_EXTRA-}"
  # A block that fails to RUN must not leave the previous .env in place and let the
  # assertions grade it. That happened once (CRLF in the extracted shell) and three
  # assertions went green against a file nothing had touched.
  if ! ( set -eo pipefail; . "$TMP/block.sh" ) > /dev/null 2> "$TMP/err"; then
    echo "  ✘ EXTRACTED BLOCK FAILED TO EXECUTE — every assertion below would be about the PREVIOUS .env:"
    sed 's/^/      /' "$TMP/err"
    exit 2
  fi
}

cd "$TMP"

# ── 1. the bug itself ───────────────────────────────────────────────────────────
echo "1. an admin rollback survives a landing deploy"
printf 'ADMIN_IMAGE_TAG=good-admin-rollback\nLANDING_IMAGE_TAG=snapshot-77\nIMAGE_TAG=snapshot-77\n' > .env
run_deploy landing snapshot-78
grep -q '^ADMIN_IMAGE_TAG=good-admin-rollback$' .env \
  && ok "ADMIN_IMAGE_TAG carried across the Doppler regeneration" \
  || bad "ADMIN_IMAGE_TAG was dropped — the rollback would jump to :latest on the next recreate"
grep -q '^LANDING_IMAGE_TAG=snapshot-78$' .env \
  && ok "LANDING_IMAGE_TAG is the tag just deployed" \
  || bad "LANDING_IMAGE_TAG is not snapshot-78"

# ── 2. `service: all`, which serializes landing then admin ──────────────────────
echo "2. deploying BOTH services leaves BOTH pinned"
printf 'ADMIN_IMAGE_TAG=old-admin\nLANDING_IMAGE_TAG=old-landing\n' > .env
run_deploy landing snapshot-79
run_deploy admin   snapshot-79
grep -q '^LANDING_IMAGE_TAG=snapshot-79$' .env && grep -q '^ADMIN_IMAGE_TAG=snapshot-79$' .env \
  && ok "both pins present after a serialized pair" \
  || bad "one pin was dropped by the second deploy: $(grep -E '_IMAGE_TAG=' .env | tr '\n' ' ')"

# ── 3. exactly one line per key ─────────────────────────────────────────────────
# The result must not depend on a later duplicate winning in compose's parser —
# nothing ever verified that assumption, so the writer removes before appending.
echo "3. every key is written exactly once"
printf 'ADMIN_IMAGE_TAG=a\nLANDING_IMAGE_TAG=b\nIMAGE_TAG=c\n' > .env
run_deploy landing snapshot-80
for k in ADMIN_IMAGE_TAG LANDING_IMAGE_TAG IMAGE_TAG; do
  n="$(grep -c "^${k}=" .env)"
  [ "$n" = "1" ] && ok "$k appears once" || bad "$k appears $n times"
done

# ── 4. a stale pin for the deploying service is replaced, not carried ───────────
echo "4. the deploying service's own stale pin is replaced"
printf 'LANDING_IMAGE_TAG=stale\n' > .env
run_deploy landing snapshot-81
grep -q '^LANDING_IMAGE_TAG=snapshot-81$' .env && ! grep -q '^LANDING_IMAGE_TAG=stale$' .env \
  && ok "replaced" || bad "the stale value survived: $(grep '^LANDING_IMAGE_TAG=' .env | tr '\n' ' ')"

# ── 5. NEGATIVE CONTROL ─────────────────────────────────────────────────────────
# The pre-fix writer, run through the same harness. If this does NOT lose the pin,
# the harness is not exercising the thing the test claims to measure and every
# green above is meaningless.
echo "5. negative control — the pre-fix writer must still fail"
printf 'ADMIN_IMAGE_TAG=good-admin-rollback\nLANDING_IMAGE_TAG=snapshot-77\n' > .env
SERVICE=landing; TAG=snapshot-78
SVC_TAG_VAR="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')_IMAGE_TAG"
doppler secrets download --format env --no-file > .env.tmp
echo "IMAGE_TAG=${TAG}" >> .env.tmp
echo "${SVC_TAG_VAR}=${TAG}" >> .env.tmp
mv .env.tmp .env
grep -q '^ADMIN_IMAGE_TAG=' .env \
  && bad "the OLD writer kept the pin — this harness cannot detect the defect, so nothing above is evidence" \
  || ok "the old writer loses the pin, as it did in production — the harness discriminates"

# ── 6. the NO-DOPPLER branch ────────────────────────────────────────────────────
# Cases 1–5 all take the `if [ -n "$DOPPLER_TOKEN" ]` branch, so the `else` — the
# path every project without a Doppler token deploys through — was measured by
# nothing. It is claimed correct on the grounds that it "amends in place", which is
# an argument, not a measurement.
echo "6. the no-Doppler branch keeps the other service's pin"
printf 'ADMIN_IMAGE_TAG=good-admin-rollback\nLANDING_IMAGE_TAG=snapshot-77\nIMAGE_TAG=snapshot-77\n' > .env
run_deploy landing snapshot-82 ""
grep -q '^ADMIN_IMAGE_TAG=good-admin-rollback$' .env \
  && ok "ADMIN_IMAGE_TAG survived a no-Doppler deploy" \
  || bad "the no-Doppler branch dropped ADMIN_IMAGE_TAG"
grep -q '^LANDING_IMAGE_TAG=snapshot-82$' .env \
  && ok "LANDING_IMAGE_TAG is the tag just deployed" \
  || bad "LANDING_IMAGE_TAG is not snapshot-82"
dupes=""
for k in ADMIN_IMAGE_TAG LANDING_IMAGE_TAG IMAGE_TAG; do
  n="$(grep -c "^${k}=" .env)"
  [ "$n" = "1" ] || dupes="${dupes} ${k}=${n}"
done
[ -z "$dupes" ] \
  && ok "every key still written exactly once" \
  || bad "wrong line counts on the no-Doppler path:${dupes}"

# The assertion above must be able to go RED, or "it amends in place" is being
# graded by a probe that would pass either way. Feed it a writer that REPLACES .env
# the way the Doppler branch does, and require the same grep to fail.
echo "   negative control — a replace-style writer must fail that same assertion"
printf 'ADMIN_IMAGE_TAG=good-admin-rollback\nLANDING_IMAGE_TAG=snapshot-77\n' > .env
printf 'NODE_ENV=production\nIMAGE_TAG=snapshot-82\nLANDING_IMAGE_TAG=snapshot-82\n' > .env.tmp
mv .env.tmp .env
grep -q '^ADMIN_IMAGE_TAG=good-admin-rollback$' .env \
  && bad "the replace-style writer kept the pin — case 6's probe cannot detect the defect" \
  || ok "it loses the pin — case 6's probe discriminates"

# ── 7. first deploy: no .env on the host at all ─────────────────────────────────
# The bare-host path is protected twice over, and it is worth writing down which is
# doing the work, because the obvious answer is wrong. `preserve_pins` opens with
# `[ -f .env ] || return 0`, and its grep also ends `|| true` — EITHER ALONE is
# enough, so deleting the guard changes no behaviour at all. Measured: tests/mutants.sh
# M1 was originally that deletion and the suite could not kill it, correctly.
# What this case does catch is the guard returning NON-ZERO, which under the block's
# `set -e` aborts the deploy — on a brand-new host, i.e. exactly where nobody is
# watching. Nothing exercised any of it before.
echo "7. a first deploy onto a host with no .env"
for tok in "stub" ""; do
  label="Doppler"; [ -n "$tok" ] || label="no-Doppler"
  rm -f .env
  run_deploy landing snapshot-83 "$tok"     # aborts the run with exit 2 if the block errors
  if [ ! -f .env ]; then
    bad "no .env was created on the $label path"
  else
    [ "$(grep -c '^IMAGE_TAG=snapshot-83$' .env)" = "1" ] \
      && [ "$(grep -c '^LANDING_IMAGE_TAG=snapshot-83$' .env)" = "1" ] \
      && ok "$label: both pins written exactly once" \
      || bad "$label: $(grep -E 'IMAGE_TAG=' .env | tr '\n' ' ')"
    # and it must not have invented a pin for a service that was never deployed
    [ "$(grep -cE '^[A-Za-z0-9_]+_IMAGE_TAG=' .env)" = "1" ] \
      && ok "$label: no pin invented for any other service" \
      || bad "$label: unexpected extra pins: $(grep -E '^[A-Za-z0-9_]+_IMAGE_TAG=' .env | tr '\n' ' ')"
  fi
done

# ── 8. a hyphenated service name ────────────────────────────────────────────────
# The workflow's own comment advertises this ("LANDING_V0_IMAGE_TAG") and the whole
# of preserve_pins turns on `[ "$key" = "$SVC_TAG_VAR" ]`. If the tr that builds
# SVC_TAG_VAR is wrong for a hyphen, the deploying service's own STALE pin is not
# recognised as its own, gets carried forward by preserve_pins, and then loses to
# the fresh append only if compose takes the last duplicate — the assumption this
# branch exists to stop depending on. Untested until now.
echo "8. a hyphenated service name (landing-v0)"
printf 'LANDING_V0_IMAGE_TAG=stale\nADMIN_IMAGE_TAG=good-admin-rollback\n' > .env
run_deploy landing-v0 snapshot-84
grep -q '^LANDING_V0_IMAGE_TAG=snapshot-84$' .env \
  && ok "LANDING_V0_IMAGE_TAG derived and written" \
  || bad "no LANDING_V0_IMAGE_TAG: $(grep -E '_IMAGE_TAG=' .env | tr '\n' ' ')"
grep -q '^LANDING_V0_IMAGE_TAG=stale$' .env \
  && bad "the stale hyphenated pin was carried forward — SVC_TAG_VAR did not match its own key" \
  || ok "its own stale pin was replaced, not carried"
[ "$(grep -c '^LANDING_V0_IMAGE_TAG=' .env)" = "1" ] \
  && ok "LANDING_V0_IMAGE_TAG appears once" \
  || bad "LANDING_V0_IMAGE_TAG appears $(grep -c '^LANDING_V0_IMAGE_TAG=' .env) times"
grep -q '^ADMIN_IMAGE_TAG=good-admin-rollback$' .env \
  && ok "the other service's rollback still survived" \
  || bad "ADMIN_IMAGE_TAG was dropped by a hyphenated-service deploy"

# ── 9. a pin coming FROM Doppler must not beat the host's rollback ──────────────
# preserve_pins deletes the dump's copy of a key and re-appends the HOST's value, so
# the host wins. That is the right precedence — a rollback is host state, and a pin
# left in Doppler would otherwise silently undo it on the next unrelated deploy —
# but it is a behaviour change from the old writer, where Doppler's value survived,
# and nothing asserted it in either direction.
echo "9. the host's pin beats a stale pin in the Doppler dump"
printf 'ADMIN_IMAGE_TAG=good-admin-rollback\n' > .env
DOPPLER_EXTRA='ADMIN_IMAGE_TAG=from-doppler' run_deploy landing snapshot-85
grep -q '^ADMIN_IMAGE_TAG=good-admin-rollback$' .env \
  && ok "host pin won" \
  || bad "Doppler's stale pin overwrote the rollback: $(grep '^ADMIN_IMAGE_TAG=' .env | tr '\n' ' ')"
[ "$(grep -c '^ADMIN_IMAGE_TAG=' .env)" = "1" ] \
  && ok "and Doppler's copy was removed, not left as a duplicate" \
  || bad "ADMIN_IMAGE_TAG appears $(grep -c '^ADMIN_IMAGE_TAG=' .env) times — the result depends on parser order"

# The probe above would also pass if it were merely detecting "an ADMIN line exists".
# Control: with NO host pin there is nothing to win, so Doppler's value must survive
# untouched. A probe that reports "host pin won" here is measuring the wrong thing.
echo "   negative control — with no host pin, Doppler's value must survive"
printf 'LANDING_IMAGE_TAG=snapshot-84\n' > .env
DOPPLER_EXTRA='ADMIN_IMAGE_TAG=from-doppler' run_deploy landing snapshot-86
grep -q '^ADMIN_IMAGE_TAG=from-doppler$' .env \
  && ok "it did — case 9 is measuring precedence, not mere presence" \
  || bad "Doppler's pin was dropped when the host had none: $(grep -E '_IMAGE_TAG=' .env | tr '\n' ' ')"
unset DOPPLER_EXTRA

echo
[ "$fail" = "0" ] && echo "PASS" || echo "FAIL"
exit "$fail"

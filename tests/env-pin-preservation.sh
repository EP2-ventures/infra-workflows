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
awk '
  /^ *preserve_pins\(\) \{/ { on=1 }
  on { print }
  on && /^ *fi *$/ { exit }
' "$WF" | sed -e 's/^            //' -e 's/\${{ inputs\.image_tag }}/${TAG}/g' > "$TMP/block.sh"

if ! grep -q 'preserve_pins .env.tmp' "$TMP/block.sh"; then
  echo "EXTRACTION FAILED: could not find the .env-writing block in $WF."
  echo "This test measured NOTHING. Fix the markers rather than deleting the test."
  exit 2
fi
echo "Extracted $(wc -l < "$TMP/block.sh") lines of the real workflow script."
echo

cat > "$TMP/doppler" <<'STUB'
#!/bin/sh
# Stands in for `doppler secrets download --format env --no-file`. The point of the
# test is what happens to the pins AROUND the dump, so the dump itself is a fixture.
printf 'NODE_ENV=production\nSOME_SECRET=xxx\n'
STUB
chmod +x "$TMP/doppler"
export PATH="$TMP:$PATH"

run_deploy() {  # $1 = service   $2 = tag
  SERVICE="$1"; TAG="$2"
  SVC_TAG_VAR="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')_IMAGE_TAG"
  DOPPLER_TOKEN="stub"
  export SERVICE TAG SVC_TAG_VAR DOPPLER_TOKEN
  ( set -eo pipefail; . "$TMP/block.sh" ) > /dev/null
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

echo
[ "$fail" = "0" ] && echo "PASS" || echo "FAIL"
exit "$fail"

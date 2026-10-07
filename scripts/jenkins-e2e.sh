#!/usr/bin/env bash
# End-to-end check in Jenkins: the multibranch job of tmail-sample/Jenkinsfile (TMail's stages) against the nginx cache.
#   master #1   cold: builds everything, the Test stage saves to the cache
#   feature-x   a change in ai-bot on a branch: reads the cache, rebuilds and retests ai-bot only, writes nothing
#   master #2   no change: the Test stage restores every module and runs no test; the image is still delivered
#   master #3   IGNORE_BUILD_CACHE=true (what nightly and tag builds do): cache off, everything rebuilt and retested.
#               The nightly timer trigger itself is not exercised: it goes through the same cache-off path
#   v1.0.0      a release tag: cache off, nothing read or written, image delivered
#
# Usage: scripts/jenkins-e2e.sh      (starts the cache server and Jenkins with docker compose)
# Output: work/jenkins-e2e/results.md, console logs in work/jenkins-e2e/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/work"
OUT="$WORK/jenkins-e2e"
BARE_REPO="$WORK/git/tmail-sample.git"
WORKING_COPY="$OUT/tmail-sample-working-copy"
RESULTS="$OUT/results.md"
JENKINS="http://localhost:8085"
JOB="$JENKINS/job/tmail-sample"
AUTH="admin:admin"
COOKIES="$OUT/cookies"
COMPOSE=(docker compose -f "$ROOT/docker-compose.yml" --profile jenkins)
TMAIL_MODULES="jmap-extensions ai-bot distributed-app integration-tests"
TMAIL_TESTS=9
AI_BOT_TESTS=3
TMAIL_ENTRIES=5

PASSED=0
FAILED=0

git_wc() {
    git -C "$WORKING_COPY" -c user.name="Build cache playground" -c user.email="playground@localhost" "$@"
}

prepare_repository() {
    # work/git is bind-mounted into Jenkins: keep the folder, replace what is inside
    mkdir -p "$WORK/git"
    rm -rf "${BARE_REPO:?}" "${WORKING_COPY:?}"
    git init -q --bare -b master "$BARE_REPO"
    mkdir -p "$WORKING_COPY"
    rsync -a --exclude target "$ROOT/tmail-sample/" "$WORKING_COPY/"
    git -C "$WORKING_COPY" init -q -b master
    git_wc add -A
    git_wc commit -q -m "TMail sample"
    git_wc remote add origin "$BARE_REPO"
    git_wc push -q origin master
}

jenkins_post() { # path
    local crumb
    crumb=$(curl -sf -u "$AUTH" -c "$COOKIES" "$JENKINS/crumbIssuer/api/json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["crumb"])')
    curl -sf -o /dev/null -u "$AUTH" -b "$COOKIES" -H "Jenkins-Crumb: $crumb" -X POST "$JENKINS$1"
}

wait_for_jenkins() {
    echo "Waiting for Jenkins and the 'tmail-sample' job..."
    for _ in $(seq 1 120); do
        curl -sf -o /dev/null -u "$AUTH" "$JOB/api/json" && return 0
        sleep 2
    done
    echo "Jenkins not ready on $JENKINS"
    exit 1
}

wait_for_build() { # branch, number
    local url="$JOB/job/$1/$2/api/json?tree=building,result"
    for _ in $(seq 1 300); do
        local state
        state=$(curl -sf -u "$AUTH" "$url" 2>/dev/null \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); print("done" if not d["building"] and d["result"] else "running")' \
            2>/dev/null || echo "pending")
        [ "$state" = "done" ] && return 0
        sleep 3
    done
    echo "build $1 #$2 did not finish"
    exit 1
}

record_build() { # branch, number, description
    local log="$OUT/$1-$2.log"
    curl -sf -u "$AUTH" "$JOB/job/$1/$2/consoleText" > "$log"
    LAST_RESULT=$(curl -sf -u "$AUTH" "$JOB/job/$1/$2/api/json?tree=result" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')
    LAST_DURATION=$(curl -sf -u "$AUTH" "$JOB/job/$1/$2/api/json?tree=duration" \
        | python3 -c 'import json,sys; print(round(json.load(sys.stdin)["duration"] / 1000))')
    # Each stage's part of the console log
    sed -n '/(Compile)/,/(Test)/p' "$log" > "$log.compile"
    sed -n '/(Test)/,/(Unstable Tests)/p' "$log" > "$log.test"
    sed -n '/(Unstable Tests)/,/(Deliver image)/p' "$log" > "$log.unstable"
    sed -n '/(Deliver image)/,$p' "$log" > "$log.deliver"
    "$ROOT/scripts/parse-build-log.sh" "$log.test" > "$log.test.modules"
    "$ROOT/scripts/parse-build-log.sh" "$log.unstable" > "$log.unstable.modules"
    LAST_HITS=$(awk '$2 == "HIT" { print $1 }' "$log.test.modules" | paste -sd ' ' -)
    LAST_BUILT=$(awk '$2 == "BUILT" { print $1 }' "$log.test.modules" | paste -sd ' ' -)
    LAST_TESTS=$(awk '{ s += $3 } END { print s + 0 }' "$log.test.modules")
    LAST_UNSTABLE_TESTS=$(awk '{ s += $3 } END { print s + 0 }' "$log.unstable.modules")
    LAST_UPLOADS=$(grep -c "Saved to remote cache .*buildinfo.xml" "$log" || true)
    LAST_REJECTED=$(grep -c "Unable to save to remote cache" "$log" || true)
    LAST_LOOKUPS=$(grep -c "Attempting to restore project" "$log.test" || true)
    LAST_COMPILE_LOOKUPS=$(grep -c "Attempting to restore project" "$log.compile" || true)
    # Only the delivery stage: the Compile and Test stages also build the image tar (jib buildTar is bound to package)
    LAST_DELIVERED=$(grep -c "Built image tarball" "$log.deliver" || true)
    # Absent when the cache is off
    LAST_FINGERPRINTED=$(awk '/build cache fingerprint: [0-9]+ modules/ { for (i = 1; i <= NF; i++) if ($i == "modules") { print $(i - 1); exit } }' "$log.test")
    echo "| $1 #$2 | $3 | $LAST_RESULT | ${LAST_DURATION}s | ${LAST_HITS:--} | ${LAST_BUILT:--} | $LAST_TESTS | $LAST_UNSTABLE_TESTS | $LAST_UPLOADS | $LAST_REJECTED | $LAST_DELIVERED |" >> "$RESULTS"
    printf '  %-12s %-9s %4ss test stage: hit=[%s] built=[%s] tests=%s | unstable=%s uploads=%s rejected=%s image=%s\n' \
        "$1 #$2" "$LAST_RESULT" "$LAST_DURATION" "$LAST_HITS" "$LAST_BUILT" "$LAST_TESTS" "$LAST_UNSTABLE_TESTS" \
        "$LAST_UPLOADS" "$LAST_REJECTED" "$LAST_DELIVERED"
}

check() { # description, shell condition
    local description=$1
    shift
    if eval "$@"; then
        echo "- PASS: $description" >> "$OUT/checks.md"
        echo "  PASS $description"
        PASSED=$((PASSED + 1))
    else
        echo "- **FAIL**: $description (condition: \`$*\`)" >> "$OUT/checks.md"
        echo "  FAIL $description"
        FAILED=$((FAILED + 1))
    fi
}

same_set() {
    [ "$(echo "$1" | tr ' ' '\n' | grep -v '^$' | sort | paste -sd ' ' -)" = \
      "$(echo "$2" | tr ' ' '\n' | grep -v '^$' | sort | paste -sd ' ' -)" ]
}

# ---------------------------------------------------------------- main

if pgrep -f '^(/[^ ]*/)?bash ([^ ]*/)?scripts/triage\.sh' > /dev/null; then
    echo "scripts/triage.sh is running and wipes the cache between scenarios: run this afterwards"
    exit 1
fi

mkdir -p "$OUT"
: > "$OUT/checks.md"
prepare_repository
# A fresh Jenkins home each run: on an existing home, jobs created by configuration as code can be overridden by the
# jobs loaded from disk
"${COMPOSE[@]}" rm -sf jenkins > /dev/null 2>&1 || true
docker volume rm -f java-build-cache_jenkins-home > /dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --build > "$OUT/compose.log" 2>&1
wait_for_jenkins
"${COMPOSE[@]}" exec -T build-cache sh -c 'find /data -mindepth 1 -maxdepth 1 ! -name .upload-tmp -exec rm -rf {} +'

{
    echo "# Jenkins end-to-end results"
    echo
    echo "Generated by \`scripts/jenkins-e2e.sh\` on $(date -u +%Y-%m-%dT%H:%MZ), pipeline \`tmail-sample/Jenkinsfile\`."
    echo "Remote cache emptied before master #1. Module and test columns are about the Test stage, the only one using the cache."
    echo
    echo "| Build | What | Result | Duration | Restored from cache | Built | Tests run | Unstable tests run | Entries uploaded | Uploads rejected | Image delivered |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|"
} > "$RESULTS"

echo "master #1: cold build"
jenkins_post "/job/tmail-sample/build?delay=0"
wait_for_build master 1
record_build master 1 "cold, saves (includes downloading dependencies)"
# The server's cleanup job verifies new entries every minute; nginx serves them only once verified. Run it now
"${COMPOSE[@]}" exec -T build-cache-evict /opt/cache-server/evict.sh > "$OUT/cleanup.log" 2>&1
check "master #1 succeeds" '[ "$LAST_RESULT" = SUCCESS ]'
check "master #1: the Compile stage does not use the cache" '[ $LAST_COMPILE_LOOKUPS -eq 0 ]'
check "master #1: the Test stage builds every module, runs every test, saves one entry per module" \
    'same_set "$LAST_BUILT" "$TMAIL_MODULES" && [ $LAST_TESTS -eq $TMAIL_TESTS ] && [ $LAST_UPLOADS -eq $TMAIL_ENTRIES ]'
check "master #1: the unstable test runs and the image is delivered" '[ $LAST_UNSTABLE_TESTS -eq 1 ] && [ $LAST_DELIVERED -eq 1 ]'
check "master #1: the Test stage fingerprints the James jars of every module first (G13)" '[ "${LAST_FINGERPRINTED:-0}" -eq 5 ]'

echo "feature-x #1: ai-bot change on a branch"
sed -i '' 's/^}$/    \/\/ changed on a branch\n}/' "$WORKING_COPY/tmail-backend/ai-bot/src/main/java/com/linagora/tmail/sample/aibot/AiBot.java"
git_wc checkout -q -b feature-x
git_wc commit -q -am "Change ai-bot"
git_wc push -q origin feature-x
git_wc checkout -q master
jenkins_post "/job/tmail-sample/build?delay=0"
wait_for_build feature-x 1
record_build feature-x 1 "ai-bot change, reads only"
check "feature-x succeeds" '[ "$LAST_RESULT" = SUCCESS ]'
check "feature-x: the Test stage rebuilds and retests ai-bot only" 'same_set "$LAST_BUILT" "ai-bot" && [ $LAST_TESTS -eq $AI_BOT_TESTS ]'
check "feature-x writes nothing (no credential, no save flag)" '[ $LAST_UPLOADS -eq 0 ] && [ $LAST_REJECTED -eq 0 ]'

echo "master #2: no change"
jenkins_post "/job/tmail-sample/job/master/buildWithParameters?IGNORE_BUILD_CACHE=false"
wait_for_build master 2
record_build master 2 "no change"
check "master #2 succeeds with an empty test report" '[ "$LAST_RESULT" = SUCCESS ]'
check "master #2: the Test stage restores every module and runs no test" 'same_set "$LAST_HITS" "$TMAIL_MODULES" && [ $LAST_TESTS -eq 0 ]'
check "master #2: the unstable test still runs (restored test classes)" '[ $LAST_UNSTABLE_TESTS -eq 1 ]'
check "master #2: the image is delivered with the app classes and glowroot files (checked by the pipeline)" '[ $LAST_DELIVERED -eq 1 ]'

echo "master #3: ignoring the cache, like nightly and tag builds"
jenkins_post "/job/tmail-sample/job/master/buildWithParameters?IGNORE_BUILD_CACHE=true"
wait_for_build master 3
record_build master 3 "IGNORE_BUILD_CACHE=true (as nightly)"
check "master #3 succeeds" '[ "$LAST_RESULT" = SUCCESS ]'
check "master #3: the Test stage rebuilds and retests every module" 'same_set "$LAST_BUILT" "$TMAIL_MODULES" && [ $LAST_TESTS -eq $TMAIL_TESTS ]'
check "master #3 neither reads nor writes the cache" '[ $LAST_LOOKUPS -eq 0 ] && [ $LAST_UPLOADS -eq 0 ] && [ $LAST_REJECTED -eq 0 ]'

echo "v1.0.0 #1: release tag"
git_wc tag v1.0.0
git_wc push -q origin v1.0.0
jenkins_post "/job/tmail-sample/build?delay=0"
for _ in $(seq 1 60); do
    curl -sf -o /dev/null -u "$AUTH" "$JOB/job/v1.0.0/api/json" && break
    sleep 2
done
# Multibranch discovers tags but does not build them on its own
jenkins_post "/job/tmail-sample/job/v1.0.0/build?delay=0"
wait_for_build v1.0.0 1
record_build v1.0.0 1 "release tag"
check "the tag build succeeds" '[ "$LAST_RESULT" = SUCCESS ]'
check "the tag build builds and tests every module from source" 'same_set "$LAST_BUILT" "$TMAIL_MODULES" && [ $LAST_TESTS -eq $TMAIL_TESTS ]'
check "the tag build neither reads nor writes the cache" '[ $LAST_LOOKUPS -eq 0 ] && [ $LAST_UPLOADS -eq 0 ] && [ $LAST_REJECTED -eq 0 ]'
check "the tag build delivers the image" '[ $LAST_DELIVERED -eq 1 ]'

leftover=$("${COMPOSE[@]}" exec -T jenkins sh -c 'find /var/jenkins_home/workspace /var/jenkins_home/.m2 -maxdepth 3 -name ".build-cache" -o -maxdepth 3 -name build-cache 2>/dev/null | wc -l' | tr -d ' \r')
check "no local build cache left on the agent after the builds" '[ "$leftover" -eq 0 ]'

{
    echo
    cat "$OUT/checks.md"
    echo
    echo "$PASSED checks passed, $FAILED failed."
} >> "$RESULTS"
echo
echo "$PASSED checks passed, $FAILED failed. Report: $RESULTS"
[ "$FAILED" -eq 0 ]

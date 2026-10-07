#!/usr/bin/env bash
# Triage of the Maven build cache proposed for TMail (docs/design.md).
#
# tmail-sample/ mirrors the layout of the TMail repository (details in tmail-sample/README.md):
#   james-project/james-core          James: TMail CI builds it, never runs its tests, never caches it
#   james-project/james-mailbox       a James module TMail only gets transitively (through james-core)
#   james-project/james-mailet        a James module only ai-bot uses
#   tmail-backend/jmap-extensions     Java + Scala sources, like tmail-backend/jmap/extensions
#   tmail-backend/ai-bot              a leaf module, like tmail-third-party/ai-bot
#   tmail-backend/distributed-app     jib buildTar bound to package, like tmail-backend/apps/distributed
#   tmail-backend/integration-tests   slow tests loading the app image by path, like the JMAP suites and deployment-tests
#
# The cache is configured in tmail-backend/.mvn/, so it only applies to builds started from tmail-backend/:
# the TMail modules. James is installed in ~/.m2 by a build from the root (or from james-project/), without cache,
# as TMail's Compile stage does today.
#
# Scenario groups:
#   M*  cache mechanics, on TMail's Test stage build ('mvn clean install' from tmail-backend/)
#   G*  guards of the cache configuration: each runs with the guard, then with the extension defaults,
#       to show that the risk is real
#   O*  operating the cache server
#   T*  whole TMail pipelines: today's stages with the cache enabled as is, the proposed stages, a variant, a release
#
# Every scenario starts from an empty remote cache, fresh agents and a pristine copy of tmail-sample.
# An "agent" has its own ~/.m2 repository and local build cache: two agents only share the remote cache,
# like two Jenkins agents (or two builds whose workspace was wiped).
#
# Usage: scripts/triage.sh [M1 G2 T2 ...]      (default: every scenario, about an hour)
# Needs: the cache server (docker compose up -d), JDK 21 and 25, Maven 3.9+, network access (base image for jib).
# Output: work/triage/results.md, build logs in work/triage/logs/
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE="$ROOT/tmail-sample"
WORK="$ROOT/work"
SEED="$WORK/m2-seed"
OUT="$WORK/triage"
CHECKOUT="$OUT/checkout"
RESULTS="$OUT/results.md"
COMPOSE=(docker compose -f "$ROOT/docker-compose.yml")
GUARDED_CONFIG="$CHECKOUT/tmail-backend/.mvn/maven-build-cache-config.xml"
UNGUARDED_CONFIG="$ROOT/scripts/configs/unguarded-cache-config.xml"
JDK25="$(/usr/libexec/java_home -v 25)"
JDK21="$(/usr/libexec/java_home -v 21)"

TMAIL_MODULES="jmap-extensions ai-bot distributed-app integration-tests"
# Stable TMail tests (the 'unstable' one is excluded by default, as in TMail)
TMAIL_TESTS=9
AI_BOT_TESTS=3
# Entries saved by a build from tmail-backend/: 4 jar modules + the tmail-backend aggregator pom
TMAIL_ENTRIES=5
APP_IMAGE="tmail-backend/distributed-app/target/jib-image.tar"
DELIVERED_IMAGE="tmail-backend/distributed-app/target/delivered-image.tar"

PASSED=0
FAILED=0

# ---------------------------------------------------------------- setup

warm_up_seed() {
    # Dependencies, plugins, the cache extension and the jib base image, downloaded once and shared read-only by every
    # agent (maven.repo.local.tail): agents then only differ by what they built or restored
    if [ -f "$SEED/.warm" ]; then
        return
    fi
    echo "Warming up $SEED (downloads dependencies once)..."
    {
        MAVEN_SKIP_RC=true mvn -B -f "$SAMPLE/pom.xml" -Dmaven.repo.local="$SEED" clean install \
            && MAVEN_SKIP_RC=true mvn -B -f "$SAMPLE/tmail-backend/pom.xml" -Dmaven.repo.local="$SEED" \
                -Dmaven.build.cache.enabled=false clean install \
            && (cd "$SAMPLE/tmail-backend" && MAVEN_SKIP_RC=true ../ci/build-cache-fingerprint.sh com.linagora.tmail.sample \
                -B -Dmaven.repo.local="$SEED") \
            && find "$SAMPLE" -name .build-cache-key -type d -prune -exec rm -rf {} + \
            && MAVEN_SKIP_RC=true mvn -B -f "$SAMPLE/pom.xml" -Dmaven.repo.local="$SEED" clean
    } > "$OUT/warm-up.log" 2>&1 || { echo "warm-up failed, see $OUT/warm-up.log"; exit 1; }
    # Agents must not find the sample's own jars there: they come from their own builds or from the cache
    rm -rf "${SEED:?}/com/linagora/tmail/sample" "${SEED:?}/org/apache/james/sample"
    touch "$SEED/.warm"
}

wait_for_cache_server() {
    for _ in $(seq 1 30); do
        curl -sf -o /dev/null http://localhost:8090/health && return 0
        sleep 1
    done
    echo "cache server not reachable on http://localhost:8090 (docker compose up -d)"
    exit 1
}

remote_entry_count() {
    "${COMPOSE[@]}" exec -T build-cache sh -c 'find /data -path /data/.upload-tmp -prune -o -name buildinfo.xml -print | wc -l' | tr -d ' \r'
}

# Runs the server's cleanup job once (evict.sh): verifies new entries, which nginx only serves once verified.
# On the real server it runs every minute; the triage pauses that loop and runs it at chosen moments, to stay deterministic
run_cleanup_job() { # log file
    "${COMPOSE[@]}" run --rm -T build-cache-evict /opt/cache-server/evict.sh >> "$1" 2>&1
}

wipe_remote_cache() {
    "${COMPOSE[@]}" exec -T build-cache sh -c 'find /data -mindepth 1 -maxdepth 1 ! -name .upload-tmp -exec rm -rf {} +'
}

reset_checkout() {
    rsync -a --delete --delete-excluded --exclude target "$SAMPLE/" "$CHECKOUT/"
}

# ---------------------------------------------------------------- scenario plumbing

start_scenario() { # id, title, TMail situation, expected outcome
    SCENARIO=$1
    CONFIG="$GUARDED_CONFIG"
    JDK="$JDK25"
    CHECKS="$OUT/checks-$SCENARIO.md"
    : > "$CHECKS"
    echo
    echo "=== $1: $2"
    reset_checkout
    wipe_remote_cache
    rm -rf "${OUT:?}/agents"
    {
        echo
        echo "## $1: $2"
        echo
        echo "TMail situation: $3"
        echo
        echo "Expected: $4"
        echo
        echo "| Build | Agent | Role | Config | JDK | Exit | Time | Restored from cache | Built | Tests run | Entries uploaded | Notes |"
        echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
    } >> "$RESULTS"
}

end_scenario() {
    echo >> "$RESULTS"
    cat "$CHECKS" >> "$RESULTS"
}

# Installs James in the agent's ~/.m2 without cache, as TMail's Compile stage does before the Test stage.
# Always on JDK 25: the James jars are the same whatever JDK the TMail build then uses.
install_james() { # agent, label
    env MAVEN_SKIP_RC=true JAVA_HOME="$JDK25" mvn -B -f "$CHECKOUT/james-project/pom.xml" \
        "-Dmaven.repo.local=$OUT/agents/$1/repository" "-Dmaven.repo.local.tail=$SEED" \
        clean install -DskipTests > "$OUT/logs/$SCENARIO-$2.james.log" 2>&1 \
        || echo "  james install failed, see $OUT/logs/$SCENARIO-$2.james.log"
}

# Runs one Maven build and parses its log into LAST_* variables.
# REACTOR: where Maven starts. "tmail-backend" (default: TMail's Test stage, the only one using the cache), "root"
#          (TMail's Compile stage: James and TMail, no cache) or "james-project" (James alone, no cache).
# INSTALL_JAMES: 1 (default) installs James first for tmail-backend builds; pipelines set 0, their Compile stage does it.
# FINGERPRINT: 1 (default) runs tmail-sample/ci/build-cache-fingerprint.sh before cache-enabled tmail-backend builds, as
#              the proposed CI does (G13); 0 skips it, to show the risk without it.
# role: master (writer credential, saves), branch (reads only), branch-tries-save (asks to save, without the credential)
run_build() { # label, agent, role, maven args...
    local label=$1 agent=$2 role=$3
    shift 3
    local agent_dir="$OUT/agents/$agent"
    local log="$OUT/logs/$SCENARIO-$label.log"
    local reactor="${REACTOR:-tmail-backend}"
    local pom="$CHECKOUT/$reactor/pom.xml"
    [ "$reactor" = root ] && pom="$CHECKOUT/pom.xml"
    mkdir -p "$agent_dir"
    if [ "$reactor" = tmail-backend ] && [ "${INSTALL_JAMES:-1}" = 1 ]; then
        install_james "$agent" "$label"
    fi
    if [ "$reactor" = tmail-backend ] && [[ " $* " != *" -Dmaven.build.cache.enabled=false "* ]]; then
        if [ "${FINGERPRINT:-1}" = 1 ]; then
            local fingerprint_log="$OUT/logs/$SCENARIO-$label.fingerprint.log"
            if ! (cd "$CHECKOUT/tmail-backend" && env MAVEN_SKIP_RC=true JAVA_HOME="$JDK" ../ci/build-cache-fingerprint.sh \
                com.linagora.tmail.sample -B -o -s "$CHECKOUT/ci/maven-settings.xml" \
                "-Dmaven.repo.local=$agent_dir/repository" "-Dmaven.repo.local.tail=$SEED") > "$fingerprint_log" 2>&1; then
                # As in the pipeline: the stage fails before the build runs
                LAST_EXIT=1 LAST_SECONDS=0 LAST_HITS="" LAST_BUILT="" LAST_TESTS=0 LAST_UPLOADS=0 LAST_LOG="$fingerprint_log"
                echo "| $label | $agent | $role | guarded | - | 1 | - | - | - | 0 | 0 | fingerprint failed, build not run |" >> "$RESULTS"
                printf '  %-24s fingerprint failed, build not run: %s\n' "$label" "$(tail -1 "$fingerprint_log" | cut -c 1-100)"
                return
            fi
        else
            find "$CHECKOUT" -name .build-cache-key -type d -prune -exec rm -rf {} +
        fi
    fi
    local args=(-B -f "$pom" -s "$CHECKOUT/ci/maven-settings.xml"
        "-Dmaven.repo.local=$agent_dir/repository" "-Dmaven.repo.local.tail=$SEED"
        "-Dmaven.build.cache.location=$agent_dir/build-cache" "-Dmaven.build.cache.configPath=$CONFIG")
    local user="" password=""
    case $role in
        master)
            user=tmail-ci
            password=tmail-ci-password
            # No remote.save.final: a later master build can then complete an entry an interrupted upload left incomplete
            args+=(-Dmaven.build.cache.remote.save.enabled=true)
            ;;
        branch-tries-save)
            args+=(-Dmaven.build.cache.remote.save.enabled=true)
            ;;
    esac

    local start
    start=$(date +%s)
    # MAVEN_SKIP_RC: ~/.mavenrc may pin JAVA_HOME, which would defeat the JDK scenario
    env MAVEN_SKIP_RC=true JAVA_HOME="$JDK" BUILD_CACHE_USER="$user" BUILD_CACHE_PASSWORD="$password" \
        mvn "${args[@]}" "$@" > "$log" 2>&1
    LAST_EXIT=$?
    LAST_SECONDS=$(( $(date +%s) - start ))
    LAST_LOG="$log"

    "$ROOT/scripts/parse-build-log.sh" "$log" > "$log.modules"
    LAST_HITS=$(awk '$2 == "HIT" { print $1 }' "$log.modules" | paste -sd ' ' -)
    LAST_BUILT=$(awk '$2 == "BUILT" { print $1 }' "$log.modules" | paste -sd ' ' -)
    LAST_TESTS=$(awk '{ s += $3 } END { print s + 0 }' "$log.modules")
    LAST_UPLOADS=$(grep -c "Saved to remote cache .*buildinfo.xml" "$log")
    LAST_UPLOAD_FAILURES=$(grep -c "Unable to save to remote cache" "$log")
    # As the cleanup job would within a minute: verify what a master build saved, so that readers can see it
    if [ "$role" = master ] && [ "$LAST_UPLOADS" -gt 0 ] && [ "${VERIFY_AFTER_SAVE:-1}" = 1 ]; then
        run_cleanup_job "$OUT/logs/$SCENARIO-cleanup.log"
    fi
    local notes
    notes=$(grep -oE "Plugin parameter mismatch found. Parameter: [A-Za-z]+, expected: [^,]*, actual: [^ ]*" "$log" \
        | sed 's/Plugin parameter mismatch found. Parameter: /mismatch /' | sort -u | head -3 | paste -sd ';' -)
    [ "$LAST_UPLOAD_FAILURES" -gt 0 ] && notes="$notes $LAST_UPLOAD_FAILURES upload(s) rejected"
    grep -q "Tests run:.*Failures: [1-9]" "$log" && notes="$notes test failure"
    [ "$LAST_TESTS" -eq 0 ] && grep -q "No tests to run" "$log" && notes="$notes 'No tests to run'"
    grep -q "Moved [0-9]* pre-existing artifacts to staging" "$log" && notes="$notes target/ outputs moved to staging"
    grep -q "Obtaining project build output files failed" "$log" && notes="$notes jib: no target/classes"

    local config_name=guarded
    [ "$CONFIG" = "$UNGUARDED_CONFIG" ] && config_name=defaults
    [[ " $* " == *" -Dmaven.build.cache.enabled=false "* ]] && config_name=off
    [ "$reactor" != tmail-backend ] && config_name="none ($reactor)"
    local jdk_name=25
    [ "$JDK" = "$JDK21" ] && jdk_name=21
    echo "| $label | $agent | $role | $config_name | $jdk_name | $LAST_EXIT | ${LAST_SECONDS}s | ${LAST_HITS:--} | ${LAST_BUILT:--} | $LAST_TESTS | $LAST_UPLOADS | ${notes:-} |" >> "$RESULTS"
    printf '  %-24s exit=%s %3ss hit=[%s] built=[%s] tests=%s uploads=%s %s\n' \
        "$label" "$LAST_EXIT" "$LAST_SECONDS" "$LAST_HITS" "$LAST_BUILT" "$LAST_TESTS" "$LAST_UPLOADS" "${notes:-}"
}

# Copies the LAST_* results of the previous build to <PREFIX>_* variables, to check several stages of a pipeline
keep() { # prefix
    eval "$1_EXIT=\$LAST_EXIT; $1_HITS=\"\$LAST_HITS\"; $1_BUILT=\"\$LAST_BUILT\"; $1_TESTS=\$LAST_TESTS; $1_UPLOADS=\$LAST_UPLOADS; $1_LOG=\"\$LAST_LOG\""
}

check() { # description, shell condition
    local description=$1
    shift
    if eval "$@"; then
        echo "- PASS: $description" >> "$CHECKS"
        echo "  PASS $description"
        PASSED=$((PASSED + 1))
    else
        echo "- **FAIL**: $description (condition: \`$*\`)" >> "$CHECKS"
        echo "  FAIL $description"
        FAILED=$((FAILED + 1))
    fi
}

note() {
    echo "- Note: $*" >> "$CHECKS"
}

same_set() { # "a b c" "c b a" -> true when same words
    [ "$(echo "$1" | tr ' ' '\n' | grep -v '^$' | sort | paste -sd ' ' -)" = \
      "$(echo "$2" | tr ' ' '\n' | grep -v '^$' | sort | paste -sd ' ' -)" ]
}

contains() { # "a b c" b
    echo " $1 " | grep -q " $2 "
}

change_file() { # file relative to the checkout: adds a comment before the closing brace, without changing behaviour
    sed -i '' 's/^}$/    \/\/ changed by the triage\n}/' "$CHECKOUT/$1"
}

change_james_api() { # a new method in a James class (default: james-core): its jar changes
    sed -i '' 's/^}$/    public static String farewell(String user) {\n        return "Bye, " + user;\n    }\n}/' "$CHECKOUT/${1:-$JAMES_SOURCE}"
}

image_is_complete() { # image tar relative to the checkout
    local dir="$OUT/image-check"
    rm -rf "$dir"
    mkdir -p "$dir"
    [ -f "$CHECKOUT/$1" ] || return 1
    tar -xf "$CHECKOUT/$1" -C "$dir"
    for layer in "$dir"/*.tar.gz; do
        tar -tzf "$layer"
    done > "$dir/content.txt"
    grep -q 'app/classes/com/linagora/tmail/sample/app/DistributedServer.class' "$dir/content.txt" \
        && grep -q 'glowroot/glowroot.properties' "$dir/content.txt"
}

AI_BOT_SOURCE=tmail-backend/ai-bot/src/main/java/com/linagora/tmail/sample/aibot/AiBot.java
JAMES_SOURCE=james-project/james-core/src/main/java/org/apache/james/sample/core/Mailbox.java
JAMES_TRANSITIVE_SOURCE=james-project/james-mailbox/src/main/java/org/apache/james/sample/mailbox/MailboxNaming.java
JAMES_MAILET_SOURCE=james-project/james-mailet/src/main/java/org/apache/james/sample/mailet/MailetNames.java
JMAP_TEST=tmail-backend/jmap-extensions/src/test/java/com/linagora/tmail/sample/jmap/JmapExtensionTest.java
SCALA_SOURCE=tmail-backend/jmap-extensions/src/main/scala/com/linagora/tmail/sample/jmap/LabelMethod.scala
IT_TEST=tmail-backend/integration-tests/src/test/java/com/linagora/tmail/sample/it/JmapIntegrationTest.java

# ---------------------------------------------------------------- TMail pipelines

# TMail's stages today (its Jenkinsfile), unchanged, with the cache present in tmail-backend/.mvn/:
#   Compile: mvn clean install -DskipTests                       (root: James and TMail, no cache)
#   Test:    mvn surefire:test                                    (tmail-backend/: the cache applies)
#   Deliver: mvn jib:build -pl apps/distributed                   (tmail-backend/; jib:buildTar here, no registry)
run_todays_pipeline() { # name, agent, role
    REACTOR=root run_build "$1-compile" "$2" "$3" clean install -DskipTests
    keep COMPILE
    INSTALL_JAMES=0 run_build "$1-test" "$2" "$3" surefire:test
    keep TEST
    INSTALL_JAMES=0 run_build "$1-deliver" "$2" "$3" -pl distributed-app jib:buildTar \
        -Djib.outputPaths.tar=target/delivered-image.tar
    keep DELIVER
}

# Proposed stages (docs/design.md, section 7). Same split as today; the Test stage becomes a lifecycle build;
# the stages reusing what the Test stage left in target/ run with the cache off.
#   Compile:        mvn clean install -DskipTests                 (root)           no cache, as today
#   Test:           mvn clean install                             (tmail-backend)  cache: read, master saves
#   Unstable Tests: mvn surefire:test -Punstable-tests            (tmail-backend)  cache: off
#   Deliver:        mvn -pl distributed-app jib:buildTar          (tmail-backend)  cache: off
# COMPILE_SCOPE=james-only (option B): the Compile stage builds the root pom and James only, so TMail is compiled once.
run_proposed_pipeline() { # name, agent, role, extra maven args for the Test stage...
    local name=$1 agent=$2 role=$3
    shift 3
    if [ "${COMPILE_SCOPE:-all}" = james-only ]; then
        REACTOR=root run_build "$name-compile-root-pom" "$agent" "$role" -N install
        REACTOR=james-project run_build "$name-compile-james" "$agent" "$role" clean install -DskipTests
    else
        REACTOR=root run_build "$name-compile" "$agent" "$role" clean install -DskipTests
    fi
    keep COMPILE
    INSTALL_JAMES=0 run_build "$name-test" "$agent" "$role" clean install "$@"
    keep TEST
    INSTALL_JAMES=0 run_build "$name-unstable" "$agent" "$role" surefire:test -Punstable-tests \
        -Dmaven.build.cache.enabled=false
    keep UNSTABLE
    rm -f "$CHECKOUT/$DELIVERED_IMAGE"
    INSTALL_JAMES=0 run_build "$name-deliver" "$agent" "$role" -pl distributed-app jib:buildTar \
        -Djib.outputPaths.tar=target/delivered-image.tar -Dmaven.build.cache.enabled=false
    keep DELIVER
}

# ---------------------------------------------------------------- M: cache mechanics (TMail's Test stage build)

m1() {
    start_scenario M1 "Cold build, saving to the remote cache" \
        "the first master build once the cache is enabled" \
        "every TMail module built, every test run, one entry per module uploaded"
    run_build cold master-1 master clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "no module restored" '[ -z "$LAST_HITS" ]'
    check "all $TMAIL_TESTS tests run" '[ $LAST_TESTS -eq $TMAIL_TESTS ]'
    check "$TMAIL_ENTRIES entries uploaded (4 modules, the tmail-backend pom)" '[ $LAST_UPLOADS -eq $TMAIL_ENTRIES ]'
    check "James is not cached" '! grep -q "james-core" "$LAST_LOG.modules" && ! grep -q "Saved to remote cache .*org.apache.james" "$LAST_LOG"'
    end_scenario
}

m2() {
    start_scenario M2 "Same commit, another agent" \
        "a PR rebuilding code master already built, or a restarted build, on another Jenkins agent" \
        "every module restored, no test run; jars still installed in ~/.m2 and the app image still built"
    run_build cold master-1 master clean install
    run_build rebuild fresh-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "every module restored" 'same_set "$LAST_HITS" "$TMAIL_MODULES"'
    check "no test run" '[ $LAST_TESTS -eq 0 ]'
    check "G6: jars installed in the agent ~/.m2 despite the hit" \
        '[ -f "$OUT/agents/fresh-agent/repository/com/linagora/tmail/sample/distributed-app/1.0.0-SNAPSHOT/distributed-app-1.0.0-SNAPSHOT.jar" ]'
    check "G5: the app image (jib buildTar) built despite the hit" '[ -f "$CHECKOUT/$APP_IMAGE" ]'
    check "the branch build uploaded nothing" '[ $LAST_UPLOADS -eq 0 ]'
    end_scenario
}

m3() {
    start_scenario M3 "Change a leaf TMail module" \
        "a PR touching only tmail-third-party/ai-bot" \
        "only ai-bot built and tested"
    run_build cold master-1 master clean install
    change_file "$AI_BOT_SOURCE"
    run_build leaf-change branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "only ai-bot built" 'same_set "$LAST_BUILT" "ai-bot"'
    check "only ai-bot tests run ($AI_BOT_TESTS)" '[ $LAST_TESTS -eq $AI_BOT_TESTS ]'
    end_scenario
}

m4() {
    start_scenario M4 "James change that changes its jar" \
        "a james-project submodule bump changing code TMail depends on (58 of 200 recent master commits bumped James)" \
        "every TMail module built and tested: the James jar is part of their keys"
    run_build cold master-1 master clean install
    change_james_api
    run_build james-api-change branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "every TMail module built" 'same_set "$LAST_BUILT" "$TMAIL_MODULES" && [ $LAST_TESTS -eq $TMAIL_TESTS ]'
    end_scenario
}

m5() {
    start_scenario M5 "James change that leaves the jars TMail uses identical" \
        "a james-project bump touching only James comments, tests, or modules TMail does not use" \
        "every TMail module restored: James jars are reproducible, so the fingerprints of the James jars each module uses do not change (G13)"
    run_build cold master-1 master clean install
    change_file "$JAMES_SOURCE"
    run_build james-comment-change branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "every TMail module restored" 'same_set "$LAST_HITS" "$TMAIL_MODULES"'
    end_scenario
}

m6() {
    start_scenario M6 "Change only a test of jmap-extensions" \
        "a PR adding a test to tmail-backend/jmap/extensions" \
        "jmap-extensions and every module depending on it built: test sources are part of the module's key"
    run_build cold master-1 master clean install
    change_file "$JMAP_TEST"
    run_build test-change branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "jmap-extensions and downstream built" 'same_set "$LAST_BUILT" "jmap-extensions distributed-app integration-tests"'
    check "ai-bot restored" 'same_set "$LAST_HITS" "ai-bot"'
    end_scenario
}

m7() {
    start_scenario M7 "Change files outside src/" \
        "a PR changing docs/, CHANGELOG.md or a module README" \
        "every module restored"
    run_build cold master-1 master clean install
    echo "# notes" > "$CHECKOUT/CHANGELOG.md"
    echo "# notes" > "$CHECKOUT/tmail-backend/ai-bot/README.md"
    run_build docs-change branch-agent branch clean install
    check "every module restored" 'same_set "$LAST_HITS" "$TMAIL_MODULES"'
    end_scenario
}

m8() {
    start_scenario M8 "James change in a module only one TMail module uses" \
        "a james-project bump changing, say, mailet code that only tmail-third-party/ai-bot uses" \
        "only ai-bot built and tested: the other modules' James fingerprints are unchanged (G13)"
    run_build cold master-1 master clean install
    change_james_api "$JAMES_MAILET_SOURCE"
    run_build james-mailet-change branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "only ai-bot built" 'same_set "$LAST_BUILT" "ai-bot"'
    check "only ai-bot tests run ($AI_BOT_TESTS)" '[ $LAST_TESTS -eq $AI_BOT_TESTS ]'
    end_scenario
}

# ---------------------------------------------------------------- G: guards, with and without

g1a() {
    start_scenario G1a "Entry saved by a build that skipped tests (-DskipTests), then a build with tests" \
        "any build with -DskipTests that saves (a developer, or a future CI stage); its entries must never count as tested" \
        "with the guard all tests run; with the extension defaults no test runs, the skipped build counts as passed"
    run_build skip-tests master-1 master clean install -DskipTests
    run_build with-tests branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "all $TMAIL_TESTS tests run" '[ $LAST_TESTS -eq $TMAIL_TESTS ]'

    CONFIG="$UNGUARDED_CONFIG"
    wipe_remote_cache
    run_build skip-tests-defaults master-2 master clean install -DskipTests
    run_build with-tests-defaults branch-agent-2 branch clean install
    check "risk with the defaults: no test runs, the build is green" '[ $LAST_EXIT -eq 0 ] && [ $LAST_TESTS -eq 0 ]'
    end_scenario
}

g1b() {
    start_scenario G1b "Entries saved by a partial test run (-Dtest, -Dsurefire.excludes) or with test failures ignored" \
        "a build running a subset of tests, excluding tests, or with -Dmaven.test.failure.ignore=true, that saves" \
        "a later normal build runs every test again, and fails when a test fails"
    run_build test-subset master-1 master clean install -Dtest=AiBotTest -Dsurefire.failIfNoSpecifiedTests=false
    run_build full-after-subset branch-agent branch clean install
    check "after a -Dtest subset: all $TMAIL_TESTS tests run" '[ $LAST_TESTS -eq $TMAIL_TESTS ]'

    cat > "$CHECKOUT/tmail-backend/ai-bot/src/test/java/com/linagora/tmail/sample/aibot/AiBotRegressionTest.java" <<'EOF'
package com.linagora.tmail.sample.aibot;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class AiBotRegressionTest {
    @Test
    void failsOnPurpose() {
        assertEquals("You said: hi", AiBot.answer("bob", "hi"));
    }
}
EOF
    wipe_remote_cache
    rm -rf "${OUT:?}/agents"
    run_build failures-ignored master-1 master clean install -Dmaven.test.failure.ignore=true
    check "the failure-ignoring build succeeds and is saved" '[ $LAST_EXIT -eq 0 ] && [ $LAST_UPLOADS -gt 0 ]'
    run_build normal-after-ignored branch-agent branch clean install
    check "the next normal build reruns ai-bot's tests and fails" '[ $LAST_EXIT -ne 0 ] && contains "$LAST_BUILT" ai-bot'

    wipe_remote_cache
    rm -rf "${OUT:?}/agents"
    run_build failing-test-excluded master-1 master clean install '-Dsurefire.excludes=**/AiBotRegressionTest.java'
    check "a build excluding the failing test succeeds and is saved" '[ $LAST_EXIT -eq 0 ] && [ $LAST_UPLOADS -gt 0 ]'
    run_build normal-after-excluded branch-agent branch clean install
    check "the next normal build reruns ai-bot's tests and fails" '[ $LAST_EXIT -ne 0 ] && contains "$LAST_BUILT" ai-bot'

    CONFIG="$UNGUARDED_CONFIG"
    wipe_remote_cache
    run_build failures-ignored-defaults master-2 master clean install -Dmaven.test.failure.ignore=true
    run_build normal-after-ignored-defaults branch-agent-2 branch clean install
    check "risk with the defaults: the next normal build is green although a test fails" '[ $LAST_EXIT -eq 0 ]'
    end_scenario
}

g2() {
    start_scenario G2 "Only a Scala source changes, breaking a test" \
        "a PR touching src/main/scala (14 TMail modules have Scala sources, 7 have Scala tests)" \
        "with the guard jmap-extensions is built and its test fails the build; with the defaults the change is ignored"
    run_build cold master-1 master clean install
    sed -i '' 's/greet("labels")/greet("labels, changed")/' "$CHECKOUT/$SCALA_SOURCE"
    run_build scala-change branch-agent branch clean install
    check "jmap-extensions built, not restored" 'contains "$LAST_BUILT" jmap-extensions && ! contains "$LAST_HITS" jmap-extensions'
    check "the build fails on the broken Scala change" '[ $LAST_EXIT -ne 0 ] && grep -q "Tests run:.*Failures: 1" "$LAST_LOG"'

    CONFIG="$UNGUARDED_CONFIG"
    wipe_remote_cache
    reset_checkout
    run_build cold-defaults master-2 master clean install
    sed -i '' 's/greet("labels")/greet("labels, changed")/' "$CHECKOUT/$SCALA_SOURCE"
    run_build scala-change-defaults branch-agent-2 branch clean install
    check "risk with the defaults: every module restored, build green, the Scala change ignored" \
        '[ $LAST_EXIT -eq 0 ] && same_set "$LAST_HITS" "$TMAIL_MODULES"'
    end_scenario
}

g3() {
    start_scenario G3 "Same commit, TMail built on another JDK (25, then 21)" \
        "a JDK upgrade on the agents (even a minor update or another vendor), or a developer on another JDK reading the CI cache" \
        "with the guard (exact JDK in the key) every module is built again; without it everything is restored"
    run_build cold-jdk25 master-1 master clean install
    JDK="$JDK21"
    run_build rebuild-jdk21 branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "every module built" 'same_set "$LAST_BUILT" "$TMAIL_MODULES"'

    # Without the guard: the JDK is no longer part of the key (build.cache.jdk forced to a constant)
    CONFIG="$UNGUARDED_CONFIG"
    JDK="$JDK25"
    wipe_remote_cache
    run_build cold-jdk25-defaults master-2 master clean install -Dbuild.cache.jdk=untracked
    JDK="$JDK21"
    run_build rebuild-jdk21-defaults branch-agent-2 branch clean install -Dbuild.cache.jdk=untracked
    check "risk without the guard: every module restored" 'same_set "$LAST_HITS" "$TMAIL_MODULES"'
    note "James jars are built on JDK 25 in both runs. In real CI a JDK change also rebuilds James, whose jar manifest records the JDK: that alone changes the TMail keys. The guard covers the case where it does not, and JDK updates of the same major version."
    end_scenario
}

g4() {
    start_scenario G4 "Master build without 'clean'" \
        "a build reusing a workspace with leftovers of an earlier build in target/" \
        "with the guard nothing is saved; with the defaults the entries are saved"
    run_build install-no-clean master-1 master install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "no entry uploaded" '[ $LAST_UPLOADS -eq 0 ]'
    run_build fresh-after branch-agent branch clean install
    check "the next agent builds every module" 'same_set "$LAST_BUILT" "$TMAIL_MODULES"'

    CONFIG="$UNGUARDED_CONFIG"
    wipe_remote_cache
    reset_checkout
    run_build install-no-clean-defaults master-2 master install
    check "risk with the defaults: entries saved from a build without clean" '[ $LAST_UPLOADS -gt 0 ]'
    end_scenario
}

g5() {
    start_scenario G5 "Only the integration tests change: the app module is restored, the tests load its image by path" \
        "a PR touching only deployment-tests or the JMAP integration tests; they load apps/*/target/jib-image.tar" \
        "with the guards the image is built (from restored classes) and the tests pass; with the defaults the build fails"
    run_build cold master-1 master clean install
    change_file "$IT_TEST"
    run_build it-change branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "only integration-tests built" 'same_set "$LAST_BUILT" "integration-tests"'

    CONFIG="$UNGUARDED_CONFIG"
    wipe_remote_cache
    reset_checkout
    run_build cold-defaults master-2 master clean install
    change_file "$IT_TEST"
    run_build it-change-defaults branch-agent-2 branch clean install
    check "risk with the defaults: the build fails, the app image is missing" \
        '[ $LAST_EXIT -ne 0 ] && grep -q "jib-image.tar" "$LAST_LOG"'
    end_scenario
}

g7() {
    start_scenario G7 "Branch build asks to save without the writer credential; overwrite attempt" \
        "a PR build (fork or not), a leaked writer credential, or another project's CI sharing the server" \
        "the build succeeds and nothing is written; nginx refuses anonymous writes (401), overwrites (409, concurrent ones included), writes into another project's folder (401) and into unknown projects (403)"
    run_build cold master-1 master clean install
    change_file "$AI_BOT_SOURCE"
    local before
    before=$(remote_entry_count)
    run_build branch-save branch-agent branch-tries-save clean install
    check "build succeeds although its uploads are rejected" '[ $LAST_EXIT -eq 0 ]'
    check "uploads were attempted and rejected" '[ $LAST_UPLOAD_FAILURES -gt 0 ]'
    check "no new entry on the server" '[ "$(remote_entry_count)" -eq "$before" ]'
    local existing
    existing=$("${COMPOSE[@]}" exec -T build-cache sh -c 'find /data/tmail -name buildinfo.xml | head -1' | tr -d '\r' | sed 's|^/data||')
    check "anonymous PUT of a new path is rejected (401)" \
        '[ "$(curl -s -o /dev/null -w "%{http_code}" -X PUT --data-binary x http://localhost:8090/tmail/v1.2/x/y/z/buildinfo.xml)" = 401 ]'
    check "TMail writer PUT over an existing entry is rejected (409)" \
        '[ "$(curl -s -o /dev/null -w "%{http_code}" -u tmail-ci:tmail-ci-password -X PUT --data-binary x "http://localhost:8090$existing")" = 409 ]'
    check "TMail writer PUT into another project's folder is rejected (401)" \
        '[ "$(curl -s -o /dev/null -w "%{http_code}" -u tmail-ci:tmail-ci-password -X PUT --data-binary x http://localhost:8090/twake-calendar/v1.2/x/y/z/buildinfo.xml)" = 401 ]'
    local race_url=http://localhost:8090/tmail/v1.2/race/test/key/file.jar
    head -c 20000 /dev/urandom > "$OUT/slow-upload.bin"
    curl -s -o /dev/null -u tmail-ci:tmail-ci-password --limit-rate 4k -X PUT --data-binary @"$OUT/slow-upload.bin" "$race_url" &
    sleep 1
    local concurrent
    concurrent=$(curl -s -o /dev/null -w "%{http_code}" -u tmail-ci:tmail-ci-password -X PUT --data-binary x "$race_url")
    wait
    check "a PUT on a path another PUT is writing is rejected (409), the first upload is kept" \
        '[ "$concurrent" = 409 ] && [ "$(curl -s "$race_url" | shasum)" = "$(shasum < "$OUT/slow-upload.bin")" ]'
    # nginx ignores limit_conn keys over 255 bytes: the lock is keyed on the entry folder, so long paths are covered too
    local long_url="http://localhost:8090/tmail/v1.2/race/test/$(printf 'k%.0s' $(seq 1 64))/$(printf 'x%.0s' $(seq 1 230)).zip"
    curl -s -o /dev/null -u tmail-ci:tmail-ci-password --limit-rate 4k -X PUT --data-binary @"$OUT/slow-upload.bin" "$long_url" &
    sleep 1
    concurrent=$(curl -s -o /dev/null -w "%{http_code}" -u tmail-ci:tmail-ci-password -X PUT --data-binary x "$long_url")
    wait
    check "same on a path longer than 255 bytes" '[ "$concurrent" = 409 ]'
    check "uploading a verification marker (.verified) is refused (403)" \
        '[ "$(curl -s -o /dev/null -w "%{http_code}" -u tmail-ci:tmail-ci-password -X PUT --data-binary x "http://localhost:8090$(dirname "$existing")/.verified")" = 403 ]'
    check "PUT into a project without a credential file is rejected (403)" \
        '[ "$(curl -s -o /dev/null -w "%{http_code}" -u tmail-ci:tmail-ci-password -X PUT --data-binary x http://localhost:8090/unknown-project/v1.2/x/y/z/buildinfo.xml)" = 403 ]'
    end_scenario
}

g13() {
    start_scenario G13 "Change in a James module TMail only gets transitively, breaking a TMail test" \
        "a james-project bump changing james-mailbox-like code (TMail declares the API module, not this one) while the jars TMail declares stay identical" \
        "with the per-module James fingerprint (transitive James jars included) every TMail module is rebuilt and the broken test fails; without it the stale results are restored"
    run_build cold master-1 master clean install
    sed -i '' 's/return user;/return user.toUpperCase();/' "$CHECKOUT/$JAMES_TRANSITIVE_SOURCE"
    run_build transitive-change branch-agent branch clean install
    # Maven stops at the first failing module, so the modules after it are not listed
    check "jmap-extensions, the first TMail module, built, not restored" 'contains "$LAST_BUILT" jmap-extensions && [ -z "$LAST_HITS" ]'
    check "the build fails on the James behaviour change" '[ $LAST_EXIT -ne 0 ] && grep -q "Tests run:.*Failures: [1-9]" "$LAST_LOG"'
    INSTALL_JAMES=0 run_build james-not-installed james-less-agent branch clean install
    check "James not installed: the fingerprint fails and the build does not run" \
        '[ $LAST_EXIT -ne 0 ] && grep -q "not found in" "$LAST_LOG" && [ ! -f "$OUT/logs/$SCENARIO-james-not-installed.log" ]'

    wipe_remote_cache
    reset_checkout
    FINGERPRINT=0 run_build cold-without-fingerprint master-2 master clean install
    sed -i '' 's/return user;/return user.toUpperCase();/' "$CHECKOUT/$JAMES_TRANSITIVE_SOURCE"
    FINGERPRINT=0 run_build transitive-change-without-fingerprint branch-agent-2 branch clean install
    check "risk without the fingerprint: every module restored, build green, the James change ignored" \
        '[ $LAST_EXIT -eq 0 ] && same_set "$LAST_HITS" "$TMAIL_MODULES"'
    end_scenario
}

g14() {
    start_scenario G14 "A root pom property used by a filtered resource changes" \
        "a change in TMail's root or tmail-backend pom (properties, dependencyManagement) that is not in any module's dependencies or plugins" \
        "with the guard (ancestor poms hashed) the modules are rebuilt and the affected test fails; with the defaults the stale results are restored"
    run_build cold master-1 master clean install
    sed -i '' 's|<ai.bot.model>gpt</ai.bot.model>|<ai.bot.model>claude</ai.bot.model>|' "$CHECKOUT/pom.xml"
    run_build root-pom-change branch-agent branch clean install
    check "ai-bot built, not restored" 'contains "$LAST_BUILT" ai-bot && ! contains "$LAST_HITS" ai-bot'
    check "the build fails on the changed model" '[ $LAST_EXIT -ne 0 ] && grep -q "Tests run:.*Failures: [1-9]" "$LAST_LOG"'

    CONFIG="$UNGUARDED_CONFIG"
    wipe_remote_cache
    reset_checkout
    run_build cold-defaults master-2 master clean install
    sed -i '' 's|<ai.bot.model>gpt</ai.bot.model>|<ai.bot.model>claude</ai.bot.model>|' "$CHECKOUT/pom.xml"
    run_build root-pom-change-defaults branch-agent-2 branch clean install
    check "risk with the defaults: every module restored, build green, the change ignored" \
        '[ $LAST_EXIT -eq 0 ] && same_set "$LAST_HITS" "$TMAIL_MODULES"'
    end_scenario
}

g16() {
    start_scenario G16 "The executed pipeline adds a Maven property to the Test stage, the workspace Jenkinsfile is older" \
        "a fork PR based on an older master: Jenkins runs the target branch's Jenkinsfile, which now passes a -D flag changing what the build produces (here a filtered resource), while the workspace still holds the old Jenkinsfile" \
        "with the guard (the executed flags repeated in build.cache.ci.flags) the modules are rebuilt and the affected test fails; without it the stale results are restored"
    run_build cold master-1 master clean install
    run_build new-pipeline-flag branch-agent branch clean install -Dai.bot.model=claude '-Dbuild.cache.ci.flags=-Dai.bot.model=claude'
    check "ai-bot built, not restored" 'contains "$LAST_BUILT" ai-bot && ! contains "$LAST_HITS" ai-bot'
    check "the build fails on the changed model" '[ $LAST_EXIT -ne 0 ] && grep -q "Tests run:.*Failures: [1-9]" "$LAST_LOG"'

    CONFIG="$UNGUARDED_CONFIG"
    wipe_remote_cache
    reset_checkout
    run_build cold-defaults master-2 master clean install
    run_build new-pipeline-flag-without-guard branch-agent-2 branch clean install -Dai.bot.model=claude
    check "risk without the guard: every module restored, build green, the flag ignored" \
        '[ $LAST_EXIT -eq 0 ] && same_set "$LAST_HITS" "$TMAIL_MODULES"'
    note "a -D override that the pipeline does not repeat in build.cache.ci.flags (a developer's command line) is still not in the key: only CI writes"
    end_scenario
}

g17() {
    start_scenario G17 "A James bump upgrades a library TMail gets transitively" \
        "a james-project bump changing a third-party version in James's dependencyManagement (here commons-lang3, which TMail gets through james-core); the James jars themselves are unchanged" \
        "with the per-module fingerprint (library versions included) every module using it is rebuilt and retested; without it everything is restored"
    run_build cold master-1 master clean install
    sed -i '' 's|<commons-lang3.version>3.17.0</commons-lang3.version>|<commons-lang3.version>3.18.0</commons-lang3.version>|' "$CHECKOUT/james-project/pom.xml"
    run_build library-upgrade branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "every TMail module built and tested (they all use james-core, hence the library)" \
        'same_set "$LAST_BUILT" "$TMAIL_MODULES" && [ $LAST_TESTS -eq $TMAIL_TESTS ]'

    wipe_remote_cache
    reset_checkout
    FINGERPRINT=0 run_build cold-without-fingerprint master-2 master clean install
    sed -i '' 's|<commons-lang3.version>3.17.0</commons-lang3.version>|<commons-lang3.version>3.18.0</commons-lang3.version>|' "$CHECKOUT/james-project/pom.xml"
    FINGERPRINT=0 run_build library-upgrade-without-fingerprint branch-agent-2 branch clean install
    check "risk without the fingerprint: every module restored, tests not run against the new library" \
        'same_set "$LAST_HITS" "$TMAIL_MODULES" && [ $LAST_TESTS -eq 0 ]'
    end_scenario
}

# ---------------------------------------------------------------- O: operating the cache server

o1() {
    start_scenario O1 "Cache server down" \
        "the nginx instance is stopped or unreachable" \
        "builds succeed without the cache"
    run_build cold master-1 master clean install
    "${COMPOSE[@]}" stop build-cache > /dev/null 2>&1
    run_build server-down branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "every module built, all tests run" 'same_set "$LAST_BUILT" "$TMAIL_MODULES" && [ $LAST_TESTS -eq $TMAIL_TESTS ]'
    run_build server-down-master master-2 master clean install
    check "a master build also succeeds" '[ $LAST_EXIT -eq 0 ]'
    "${COMPOSE[@]}" start build-cache > /dev/null 2>&1
    wait_for_cache_server
    end_scenario
}

o2() {
    start_scenario O2 "Incomplete entry on the server" \
        "an upload that failed half-way" \
        "the module with the incomplete entry is built again, the others restored; the next master build completes the entry"
    run_build cold master-1 master clean install
    "${COMPOSE[@]}" exec -T build-cache sh -c 'find /data/tmail -path "*/ai-bot/*" -name "ai-bot.jar" -delete'
    run_build incomplete branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "ai-bot built, the others restored" 'same_set "$LAST_BUILT" "ai-bot"'
    run_build repair master-2 master clean install
    check "the next master build uploads the missing file" 'grep -q "Saved to remote cache .*ai-bot.jar" "$LAST_LOG"'
    run_build after-repair branch-agent-2 branch clean install
    check "the entry is complete again: every module restored" 'same_set "$LAST_HITS" "$TMAIL_MODULES"'
    end_scenario
}

o3() {
    start_scenario O3 "Eviction of old entries" \
        "the nightly eviction job deleting entries older than the retention" \
        "the evicted module is built again, the others restored"
    run_build cold master-1 master clean install
    "${COMPOSE[@]}" exec -T build-cache sh -c 'find /data/tmail -path "*/ai-bot/*" -exec touch -d "2020-01-01 00:00:00" {} +'
    # An incomplete upload from two days ago: files without buildinfo.xml
    "${COMPOSE[@]}" exec -T build-cache sh -c 'mkdir -p /data/tmail/v1.2/g/a/orphan && touch -d "$(date -d @$(( $(date +%s) - 172800 )) "+%Y-%m-%d %H:%M:%S")" /data/tmail/v1.2/g/a/orphan/a.jar'
    : > "$OUT/logs/$SCENARIO-evict.log"
    run_cleanup_job "$OUT/logs/$SCENARIO-evict.log"
    local evict_exit=$?
    check "the eviction script ran and deleted the whole old ai-bot entry" \
        '[ $evict_exit -eq 0 ] && grep -q "expired: .*/ai-bot/" "$OUT/logs/$SCENARIO-evict.log"'
    check "it deleted the incomplete upload" 'grep -q "incomplete upload: .*/orphan" "$OUT/logs/$SCENARIO-evict.log"'
    check "the upload folder survived eviction" \
        '"${COMPOSE[@]}" exec -T build-cache test -d /data/.upload-tmp'
    run_build after-eviction branch-agent branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "only ai-bot built" 'same_set "$LAST_BUILT" "ai-bot"'
    end_scenario
}

o4() {
    start_scenario O4 "New entries are only served once verified; an inconsistent one is deleted" \
        "an upload interrupted, then completed by another build of the same key: files of one build, metadata of another" \
        "before verification no entry is served; the cleanup job deletes the inconsistent ai-bot entry and publishes the others"
    VERIFY_AFTER_SAVE=0 run_build cold master-1 master clean install
    local entry
    entry=$("${COMPOSE[@]}" exec -T build-cache sh -c 'find /data/tmail -path "*/ai-bot/*" -name buildinfo.xml | head -1' | tr -d '\r' | sed 's|^/data||; s|/buildinfo.xml$||')
    check "an entry not yet verified is not served (404 on its buildinfo.xml)" \
        '[ "$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8090$entry/buildinfo.xml")" = 404 ]'
    run_build before-verification branch-agent branch clean install
    check "so a build before verification restores nothing" '[ -z "$LAST_HITS" ]'
    "${COMPOSE[@]}" exec -T build-cache sh -c "echo other-build >> /data$entry/ai-bot.jar"
    : > "$OUT/logs/$SCENARIO-cleanup-run.log"
    run_cleanup_job "$OUT/logs/$SCENARIO-cleanup-run.log"
    check "the cleanup job deleted the inconsistent ai-bot entry" 'grep -q "inconsistent (ai-bot.jar): .*/ai-bot/" "$OUT/logs/$SCENARIO-cleanup-run.log"'
    run_build after-verification branch-agent-2 branch clean install
    check "build succeeds" '[ $LAST_EXIT -eq 0 ]'
    check "the verified entries are served, ai-bot is built again" 'same_set "$LAST_BUILT" "ai-bot"'
    # A file replaced after verification (the residual upload race of docs/design.md section 10): checked again, entry deleted
    "${COMPOSE[@]}" exec -T build-cache sh -c 'f=$(find /data/tmail -path "*/distributed-app/*" -name distributed-app.jar | head -1); sleep 1; echo late >> "$f"'
    : > "$OUT/logs/$SCENARIO-cleanup-late.log"
    run_cleanup_job "$OUT/logs/$SCENARIO-cleanup-late.log"
    check "a file changed after verification is checked again and its entry deleted" \
        'grep -q "inconsistent (distributed-app.jar): .*/distributed-app/" "$OUT/logs/$SCENARIO-cleanup-late.log"'
    end_scenario
}

# ---------------------------------------------------------------- T: whole TMail pipelines

t1() {
    start_scenario T1 "Today's stages unchanged, the cache added to tmail-backend/" \
        "today's Jenkinsfile as is: Compile 'install -DskipTests' from the root, Test 'surefire:test' and jib delivery from tmail-backend/" \
        "the Test stage runs no test yet passes, and the delivery fails: a cached Maven run moves the existing target/ outputs aside before running"
    run_todays_pipeline first master-1 master
    check "the Compile stage (root) does not use the cache" '! grep -q "Attempting to restore project" "$COMPILE_LOG"'
    check "risk: the Test stage runs 0 tests and passes ('No tests to run')" \
        '[ $TEST_EXIT -eq 0 ] && [ $TEST_TESTS -eq 0 ] && grep -q "No tests to run" "$TEST_LOG"'
    check "cause: target/ outputs moved to staging before surefire ran" 'grep -q "pre-existing artifacts to staging" "$TEST_LOG"'
    check "risk: the delivery fails (jib finds no target/classes)" \
        '[ $DELIVER_EXIT -ne 0 ] && grep -q "Obtaining project build output files failed" "$DELIVER_LOG"'
    end_scenario
}

t2() {
    start_scenario T2 "Proposed pipeline: same split, the Test stage becomes 'clean install'" \
        "proposed Jenkinsfile (docs/design.md, section 7): Compile as today, Test 'clean install' from tmail-backend/, Unstable Tests and delivery with the cache off" \
        "unchanged TMail modules are neither rebuilt nor retested; James is never cached nor tested; unstable tests and the delivery keep working"
    run_proposed_pipeline p1 master-1 master
    check "P1 cold master: the Compile stage does not use the cache" '! grep -q "Attempting to restore project" "$COMPILE_LOG"'
    check "P1: the Test stage runs the $TMAIL_TESTS TMail tests and saves $TMAIL_ENTRIES entries" \
        '[ $TEST_EXIT -eq 0 ] && [ $TEST_TESTS -eq $TMAIL_TESTS ] && [ $TEST_UPLOADS -eq $TMAIL_ENTRIES ]'
    check "P1: James tests never run" '[ $COMPILE_TESTS -eq 0 ] && ! grep -q "Running org.apache.james" "$TEST_LOG"'
    check "P1: the unstable test runs" '[ $UNSTABLE_TESTS -eq 1 ]'
    check "P1: the delivered image holds the app classes and glowroot files" '[ $DELIVER_EXIT -eq 0 ] && image_is_complete "$DELIVERED_IMAGE"'

    run_proposed_pipeline p2 fresh-agent branch
    check "P2 no change, another agent: the Test stage restores every module and runs no test" \
        'same_set "$TEST_HITS" "$TMAIL_MODULES" && [ $TEST_TESTS -eq 0 ]'
    check "P2: the unstable test still runs (on restored test-classes)" '[ $UNSTABLE_EXIT -eq 0 ] && [ $UNSTABLE_TESTS -eq 1 ]'
    check "P2: the delivered image holds the app classes and glowroot files (restored classes)" '[ $DELIVER_EXIT -eq 0 ] && image_is_complete "$DELIVERED_IMAGE"'

    change_file "$AI_BOT_SOURCE"
    run_proposed_pipeline p3 branch-agent-3 branch
    check "P3 ai-bot change: the Test stage builds and tests ai-bot only" 'same_set "$TEST_BUILT" "ai-bot" && [ $TEST_TESTS -eq $AI_BOT_TESTS ]'

    reset_checkout
    sed -i '' 's/return user;/return user.toUpperCase();/' "$CHECKOUT/$JAMES_TRANSITIVE_SOURCE"
    run_proposed_pipeline p4 branch-agent-4 branch
    check "P4 change in a James module TMail only gets transitively: the Test stage rebuilds and its tests fail" \
        'contains "$TEST_BUILT" jmap-extensions && [ -z "$TEST_HITS" ] && [ $TEST_EXIT -ne 0 ]'

    reset_checkout
    change_james_api
    run_proposed_pipeline p5 branch-agent-5 branch
    check "P5 James API change: the Test stage builds and tests every TMail module" \
        'same_set "$TEST_BUILT" "$TMAIL_MODULES" && [ $TEST_TESTS -eq $TMAIL_TESTS ]'

    reset_checkout
    sed -i '' 's/greet("labels")/greet("labels, changed")/' "$CHECKOUT/$SCALA_SOURCE"
    run_proposed_pipeline p6 branch-agent-6 branch
    check "P6 broken Scala change: the Test stage fails" '[ $TEST_EXIT -ne 0 ]'
    end_scenario
}

t3() {
    start_scenario T3 "Variant (option B): the Compile stage builds James only" \
        "the same pipeline, but Compile no longer compiles TMail (built and tested once, in the Test stage); the fingerprint step only needs James installed" \
        "the cache behaves as in T2, including the per-module James fingerprint"
    COMPILE_SCOPE=james-only run_proposed_pipeline p1 master-1 master
    check "P1 cold master: the Test stage runs the $TMAIL_TESTS TMail tests" '[ $TEST_EXIT -eq 0 ] && [ $TEST_TESTS -eq $TMAIL_TESTS ]'
    check "P1: the delivered image holds the app classes and glowroot files" '[ $DELIVER_EXIT -eq 0 ] && image_is_complete "$DELIVERED_IMAGE"'
    COMPILE_SCOPE=james-only run_proposed_pipeline p2 fresh-agent branch
    check "P2 no change, another agent: the Test stage restores every module and runs no test" \
        'same_set "$TEST_HITS" "$TMAIL_MODULES" && [ $TEST_TESTS -eq 0 ]'
    check "P2: the unstable test runs and the delivered image is complete" \
        '[ $UNSTABLE_TESTS -eq 1 ] && [ $DELIVER_EXIT -eq 0 ] && image_is_complete "$DELIVERED_IMAGE"'
    change_james_api "$JAMES_MAILET_SOURCE"
    COMPILE_SCOPE=james-only run_proposed_pipeline p3 branch-agent-3 branch
    check "P3 James change only ai-bot uses: the Test stage builds and tests ai-bot only" \
        'same_set "$TEST_BUILT" "ai-bot" && [ $TEST_TESTS -eq $AI_BOT_TESTS ]'
    end_scenario
}

t4() {
    start_scenario T4 "Release tag pipeline: cache off" \
        "a tag build, which delivers the release images" \
        "nothing read from or written to the cache, every TMail module built and tested from source, even right after master saved the same commit"
    run_proposed_pipeline master master-1 master
    local before
    before=$(remote_entry_count)
    run_proposed_pipeline tag tag-agent branch -Dmaven.build.cache.enabled=false
    check "the Test stage builds and tests every TMail module" 'same_set "$TEST_BUILT" "$TMAIL_MODULES" && [ $TEST_TESTS -eq $TMAIL_TESTS ]'
    check "no cache lookup" '! grep -q "Attempting to restore project" "$COMPILE_LOG" "$TEST_LOG"'
    check "nothing written to the cache" '[ "$(remote_entry_count)" -eq "$before" ] && [ ! -d "$OUT/agents/tag-agent/build-cache" ]'
    check "the delivered image holds the app classes and glowroot files" '[ $DELIVER_EXIT -eq 0 ] && image_is_complete "$DELIVERED_IMAGE"'
    end_scenario
}

# ---------------------------------------------------------------- main

mkdir -p "$OUT/logs"
wait_for_cache_server
warm_up_seed
# The triage runs the cleanup job itself (run_cleanup_job); the server's own loop would run it at random moments
"${COMPOSE[@]}" stop build-cache-evict > /dev/null 2>&1
trap '"${COMPOSE[@]}" start build-cache-evict > /dev/null 2>&1' EXIT

if [ $# -eq 0 ]; then
    set -- M1 M2 M3 M4 M5 M6 M7 M8 G1a G1b G2 G3 G4 G5 G7 G13 G14 G16 G17 O1 O2 O3 O4 T1 T2 T3 T4
fi

{
    echo "# Triage results"
    echo
    echo "Generated by \`scripts/triage.sh\` on $(date -u +%Y-%m-%dT%H:%MZ), Maven $(mvn -v 2>/dev/null | head -1 | awk '{print $3}'), build cache extension 1.3.0."
    echo "Each scenario starts from an empty remote cache, fresh agents and a pristine tmail-sample."
    echo "Builds run from tmail-backend/ unless the Config column says otherwise; each is preceded by a James install"
    echo "without cache (logs: *.james.log), as TMail's Compile stage does, and cache-enabled ones by the fingerprint step"
    echo "(ci/build-cache-fingerprint.sh, logs: *.fingerprint.log) unless a scenario says otherwise. Config: guarded ="
    echo "tmail-sample/tmail-backend/.mvn/maven-build-cache-config.xml, defaults = extension defaults"
    echo "(scripts/configs/unguarded-cache-config.xml), off = -Dmaven.build.cache.enabled=false,"
    echo "none = a build outside tmail-backend/, which does not load the cache extension."
} > "$RESULTS"

for scenario in "$@"; do
    fn=$(echo "$scenario" | tr '[:upper:]' '[:lower:]')
    "$fn"
done

{
    echo
    echo "## Summary"
    echo
    echo "$PASSED checks passed, $FAILED failed."
} >> "$RESULTS"
echo
echo "$PASSED checks passed, $FAILED failed. Report: $RESULTS"
[ "$FAILED" -eq 0 ]

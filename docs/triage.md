# Triage: does the build cache work for TMail, and is it safe?

Run on 2026-10-07, macOS arm64, Docker 29.6, Maven 3.9.16, JDK 25 (GraalVM) and 21 (Homebrew OpenJDK),
build cache extension 1.3.0, nginx 1.29, Jenkins LTS on JDK 25, on [`tmail-sample/`](../tmail-sample/README.md),
a small build mirroring TMail's layout and CI stages, including the Test stage as two parallel branches (TMail branch
`fasten-tmail-build-08-10-2026`).
Full generated tables: [triage-report.md](triage-report.md) (29 scenarios, 120 checks) and
[jenkins-e2e-report.md](jenkins-e2e-report.md) (5 Jenkins builds, 20 checks). All checks pass.
The design was reviewed in several rounds by Codex (gpt-6.1-sol, xhigh); its findings led to guards G13 to G16, the jib extra-files handling,
the verification of entries before they are served, whole-entry eviction, writes serialized per entry, the CI flags in the key,
a fingerprint script that fails on any gap, and the residual risks listed in the design (section 10).

## Verdict

- **It works with off-the-shelf parts.** The extension and plain nginx are enough; no cache server has to be written.
  In the Test stage, the same commit on another agent takes **2s instead of 31s** with no test run; a leaf module change, 9s.
- **Only with the guards.** Every risk in the design was reproduced without its guard: with the defaults, the cache reuses builds
  that skipped or excluded tests, ignores Scala changes, JDK changes, parent pom changes, new CI flags and transitive James changes,
  and breaks the tests that load the app image by path. With the guards, each case rebuilds, and the broken change fails the build.
- **TMail's Jenkinsfile needs changes.** Kept as is, both `surefire:test` branches pass with 0 tests and the delivery fails (T1).
  The proposed stages (Compile unchanged; a Prepare Test step writing the fingerprints and copying the sources; each Test branch
  `clean verify -pl ...`, the other modules' one on the copy; Unstable Tests and delivery with the cache off) work, on fresh agents
  too, including the unstable tests and a complete image (T2, Jenkins). A change in one branch's modules reaches the other
  branch's (T2 P4, G18).
- **The two Test branches must not share a source tree** (T3): `clean` in the other modules' branch deletes the app image while
  the deployment tests load it. In two of the last three runs, a deployment test failed on the missing file, passed on the
  `-Pci-test` retry, and the build stayed green.
- **TMail's jars must be reproducible** (G19): `logback-contrib`, rebuilt by every Compile stage, would otherwise keep the app
  and the integration tests from ever being restored.
- **James is never cached nor tested.** A James bump only retests the TMail modules whose dependency tree holds a James jar it
  changed, transitive ones included (M5, M8, G13); a library version James upgrades counts as a change too (G17). This relies on
  James jars being reproducible, checked on real James modules ([estimate.md](estimate.md)). If James is missing, the fingerprint
  step fails and the build does not run.

## Time saved on the sample (Test stage)

The sample has 4 TMail modules and 9 tests sleeping 1–4s each, to stand for TMail's slow tests. "One build" is a single
`clean install` of every TMail module (M, G scenarios); "two branches" is the proposed Test stage, its two `clean verify -pl`
builds side by side (T2, G19), timed until the slower one ends. Timings are the Maven builds, start-up included; the fingerprint
step before them adds 5 to 7s on the sample (three short Maven runs), about 20s on TMail. The machine was shared with other
builds, so timings vary by a few seconds between runs.

| Situation | One build | Two branches | Tests run | Scenario |
|---|---|---|---|---|
| Cold (empty cache) | 31s | 18s | 9 | M1, T2 P1 |
| Same commit, another agent | 2s | 3s | 0 | M2, T2 P2 |
| Docs or module README change | 3s | | 0 | M7 |
| James change leaving the jars TMail uses identical (comments, tests, unused modules) | 3s | | 0 | M5 |
| Leaf module (`ai-bot`) changed | 9s | 12s | 3 | M3, T2 P3 |
| James change in a module only `ai-bot` uses | 8s | | 3 | M8 |
| Integration tests changed | 16s | | 3 | G5 |
| `logback-contrib` changed (the app and the integration tests) | | 16s | 4 | G19 P3 |
| `jmap-extensions` changed (it, the app, and the integration tests in the other branch) | | 17s | 6 | T2 P4 |
| Test of a core module changed | 25s | | 6 | M6 |
| James change in a module every TMail module uses | 31s | 18s | 9 | M4, T2 P6 |
| Library upgraded by a James bump, used by every module | 31s | | 9 | G17 |

Savings follow the dependency graph, James included: a change in a module everything depends on saves nothing.

## Guards: with and without

| Risk | Without the guard | With the guard | Scenario |
|---|---|---|---|
| Entry saved with `-DskipTests` | **0 tests run**, build green | All tests run | G1a |
| Entry saved with test failures ignored, or a failing test excluded | **Build green although a test fails** | Tests rerun, build fails | G1b |
| Scala source change breaking a test | **All restored, build green** | Module rebuilt, build fails | G2 |
| Same commit on another JDK | **All restored** | All rebuilt | G3 |
| Build without `clean` | Saved | Not saved | G4 |
| App restored, tests load its image by path | **Build fails: image missing** | Image built from restored classes, with its glowroot files | G5 |
| Change in a James module TMail only gets transitively, breaking a test | **All restored, build green** | All rebuilt, build fails | G13 |
| James bump upgrading a library TMail gets through James | **All restored, tests not run against the new library** | Modules using it rebuilt and retested | G17 |
| Test stage split in two `-pl` builds; `jmap-extensions` changes, the integration tests get it through the app built in the other branch | **Integration tests restored, not run** (keyed by the app's unchanged jar) | Rebuilt and retested (multi-module discovery) | G18 |
| A TMail module outside `tmail-backend/` (`logback-contrib`), rebuilt by every Compile stage, jars not reproducible | **App and integration tests rebuilt on every build** | Restored when nothing changed; rebuilt when it changes | G19 |
| A Test branch's tree lacks the fingerprints | Keys ignore James and `logback-contrib`: stale results after a James change | The branch refuses to build (`--check`) | G13 |
| Root pom property used by a filtered resource | **All restored, build green** | Rebuilt, build fails | G14 |
| New `-D` flag in the executed pipeline (older Jenkinsfile in the workspace, as for fork PRs), changing a filtered resource | **All restored, build green** | Rebuilt, build fails | G16 |
| Branch build saving without credential; overwrite (sequential, concurrent, on long paths); verification marker upload; another project's folder; unknown project | n/a | 401, 409, 403, 401, 403; nothing written; build green | G7 |

## Operating the server

| Situation | Outcome | Scenario |
|---|---|---|
| Cache server stopped | Builds green, everything built (master too) | O1 |
| Incomplete entry (a jar missing) | That module rebuilt; the next master build uploads the missing jar; then every module is restored again | O2 |
| Entry older than the retention, incomplete upload older than a day | Deleted whole; only that module rebuilt; upload folder untouched | O3 |
| New entry not verified yet | Not served (404), so a build restores nothing from it | O4 |
| Entry whose files do not match its `buildinfo.xml` | Deleted by the cleanup job's verification before being served; only that module rebuilt | O4 |
| File replaced after verification | Checked again at the next cleanup, entry deleted | O4 |

## TMail pipeline

| Pipeline | Outcome | Scenario |
|---|---|---|
| Today's stages (two parallel `surefire:test` branches), cache added to `tmail-backend/` | **Both Test branches run 0 tests and pass** (outputs moved aside by the cache-enabled run); delivery fails | T1 |
| Proposed: Compile as today; Prepare Test (fingerprints, copy of the sources next to the workspace); two parallel `clean verify -pl` branches, the other modules' one on the copy; Unstable Tests and delivery cache off | Compile never touches the cache; James tests never run; on another agent both branches restore all and run 0 tests, and so does one build of every module in the workspace (keys independent of the split and of the tree); the unstable test still runs; the image holds classes and glowroot files; a `jmap-extensions` change rebuilds it, the app and, in the other branch, the integration tests; transitive James and broken Scala changes fail the Test stage; the image the deployment tests load never disappears | T2 |
| The two Test branches sharing one source tree | The app image disappears while the other branch rebuilds the app; a deployment test can fail on it, and pass on a retry | T3 |
| Release tag, cache off | Today's Test stage commands with the cache off: every module tested; no lookup; nothing written; image complete | T4 |

## Jenkins

The multibranch job of [`tmail-sample/Jenkinsfile`](../tmail-sample/Jenkinsfile), against the cache server, on a fresh Jenkins.
Durations are whole pipelines (Compile, Prepare Test, the two Test branches, Unstable Tests, delivery). Each pipeline has its own
local repository (G21) and this Jenkins starts with an empty `~/.m2`, so every pipeline downloads all its dependencies: about
30s of each duration. On TMail's agents, `~/.m2` would provide them.

| Build | Duration | Test stage | Notes |
|---|---|---|---|
| master #1, cold | 87s | 9 tests, 4 entries saved | 5 modules fingerprinted; the other modules' branch on `<workspace>@test-modules`; both branches checked their fingerprints; entries verified by the cleanup job before the next build |
| `feature-x`, `ai-bot` change | 68s | `ai-bot` only, 3 tests | writes nothing |
| master #2, no change | 60s | all restored, 0 tests | unstable test still runs; image complete |
| master #3, `IGNORE_BUILD_CACHE` (nightly path) | 61s | 9 tests | today's Test stage commands, cache off: no fingerprint, no copy, nothing read or written |
| tag `v1.0.0` | 61s | 9 tests | cache neither read nor written; image delivered |

No local cache, repository or copy of the sources is left on the agent afterwards.

## Problems found during the triage (fixed)

- Parallel Test branches: Jenkins' console text interleaves their lines without naming the branch, so the e2e script reads the
  Test stage from the lines naming their module instead of parsing it module by module (found by Codex).
- Parallel Test branches: two pipelines sharing one agent's `~/.m2` could test each other's jars, and a master build save the
  result under its own keys (found by Codex). Each pipeline now has its own local repository (G21).

- nginx: the "no overwrite" rule inside the `location` with `limit_except` was silently skipped for PUT. Moved to server level.
- `evict.sh`: with GNU `find`, `-delete` disables `-prune`; eviction could delete nginx's upload folder. Rewritten, tested with
  BusyBox and GNU `find`; it now evicts whole entries.
- Single-file bind mounts go stale when the file is replaced: the eviction container lost its script. It mounts the folder now.
- `~/.mavenrc` pinned JDK 25 for every `mvn` call, so the JDK scenario first ran twice on JDK 25. The triage sets `MAVEN_SKIP_RC=true`.
- Several checks expected every module to be built when the build fails: Maven stops at the first failing module.
- A wait loop in my tooling matched the e2e script's "is the triage running?" guard. The guard now matches the script itself only.
- The sample Jenkinsfile first put the James revision in the key, computed from `tmail-backend/`, where `git log -- james-project`
  finds nothing: an empty revision would have silently dropped G13. Replaced by the per-module fingerprint, which fails the
  stage on any gap; the Jenkins run checks every module is fingerprinted.
- The fingerprint first used `dependency:build-classpath`, which needs the project's own modules installed: in the Test stage
  they are not yet. It now uses `dependency:tree`, which only collects the graph.
- Codex found the first fingerprint script ignored failures inside a process substitution and dropped the dependency scopes.
  Rewritten: any failure, an unknown tree line or a module without fingerprint fails it (checked in G13), and scopes are kept.
- Jenkins started on an existing home volume kept an old job instead of the configured one; the e2e script starts on a fresh home.
- Parallel Test branches: the first copy of the sources for the other modules' branch dropped the fingerprints (a `tar` exclude
  meant for the local cache folders matched `.build-cache-key/` with BSD tar), and that branch silently restored stale results
  after a transitive James change (T2 P5 failed). The exclude is gone, and each branch now runs
  `ci/build-cache-fingerprint.sh --check` before building (G13).
- The first proposed Jenkinsfile ran the cache-off Test branches (tags, nightly) with today's `surefire:test`, forgetting that
  `tmail-backend/.mvn/` enables the cache by default: T1's 0-test trap. They now pass `-Dmaven.build.cache.enabled=false`.
- The log parser missed surefire's summary line when a test passed on a retry (`, Flakes: 1`), counting 0 tests (T3).
- Codex review of the parallel branches: the copy inside the workspace gave modules other keys than in the workspace (moved next
  to it, checked in T2); the fingerprint matched reactor modules without their version (an external dependency bringing another
  version of a reactor module would have gone unhashed); several positive checks did not require the build to succeed; the e2e
  script counted a rejected restore as a hit (it now reports the Test stage as undetermined).

## Not covered

- TMail itself: real hit rate, entry sizes, restore and upload times, jib `buildTar` cost on fully cached builds, the
  fingerprint step on CI agents (run on a copy of TMail on a laptop only).
- Two pipelines at once on one agent (G21): the Jenkinsfile gives each pipeline its own local repository; the triage gives each
  agent its own, and the Jenkins run builds one pipeline at a time.
- `failFast` aborting the other Test branch in the middle of a master upload: covered by the incomplete-entry scenarios (O2, O4),
  not by an aborted Jenkins run.
- Parallel builds (`-T1C`) in the Test stage.
- The nightly timer trigger (it uses the same cache-off path as `IGNORE_BUILD_CACHE`, which is tested).
- Two master builds uploading the same key at the same moment: the per-path write limit is tested with overlapping uploads (G7),
  not with two real builds.

## Reproduce

```bash
docker compose up -d
scripts/triage.sh            # or a subset: scripts/triage.sh G13 T2
scripts/jenkins-e2e.sh       # not at the same time as triage.sh
```

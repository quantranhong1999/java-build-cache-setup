# Triage: does the build cache work for TMail, and is it safe?

Run on 2026-10-07, macOS arm64, Docker 29.6, Maven 3.9.16, JDK 25 (GraalVM) and 21 (Homebrew OpenJDK),
build cache extension 1.3.0, nginx 1.29, Jenkins LTS on JDK 25, on [`tmail-sample/`](../tmail-sample/README.md),
a small build mirroring TMail's layout and CI stages.
Full generated tables: [triage-report.md](triage-report.md) (27 scenarios, 113 checks) and
[jenkins-e2e-report.md](jenkins-e2e-report.md) (5 Jenkins builds, 20 checks). All checks pass.
The design was reviewed in several rounds by Codex (gpt-6.1-sol, xhigh); its findings led to guards G13 to G16, the jib extra-files handling,
the verification of entries before they are served, whole-entry eviction, writes serialized per entry, the CI flags in the key,
a fingerprint script that fails on any gap, and the residual risks listed in the design (section 10).

## Verdict

- **It works with off-the-shelf parts.** The extension and plain nginx are enough; no cache server has to be written.
  In the Test stage, the same commit on another agent takes **3s instead of 30s** with no test run; a leaf module change, 13s.
- **Only with the guards.** Every risk in the design was reproduced without its guard: with the defaults, the cache reuses builds
  that skipped or excluded tests, ignores Scala changes, JDK changes, parent pom changes, new CI flags and transitive James changes,
  and breaks the tests that load the app image by path. With the guards, each case rebuilds, and the broken change fails the build.
- **TMail's Jenkinsfile needs changes.** Kept as is, the `surefire:test` stage passes with 0 tests and the delivery fails (T1).
  The proposed stages (Compile unchanged, Test `clean install`, Unstable Tests and delivery with the cache off) work, on fresh agents
  too, including the unstable tests and a complete image (T2, Jenkins).
- **James is never cached nor tested.** A James bump only retests the TMail modules whose dependency tree holds a James jar it
  changed, transitive ones included (M5, M8, G13); a library version James upgrades counts as a change too (G17). This relies on
  James jars being reproducible, checked on real James modules ([estimate.md](estimate.md)). If James is missing, the fingerprint
  step fails and the build does not run.

## Time saved on the sample (Test stage)

The sample has 4 TMail modules and 9 tests sleeping 1–4s each, to stand for TMail's slow tests. Timings are the Maven build,
start-up included; the fingerprint step before it adds 5 to 7s on the sample (three short Maven runs), about 17s on TMail.
The machine was shared with other builds, so timings vary by a few seconds between runs.

| Situation | Time | Tests run | Scenario |
|---|---|---|---|
| Cold (empty cache) | 33s | 9 | M1 |
| Same commit, another agent | 3s | 0 | M2, T2 P2 |
| Docs or module README change | 3s | 0 | M7 |
| James change leaving the jars TMail uses identical (comments, tests, unused modules) | 4s | 0 | M5 |
| Leaf module (`ai-bot`) changed | 13s | 3 | M3, T2 P3 |
| James change in a module only `ai-bot` uses | 14s | 3 | M8, T3 P3 |
| Integration tests changed | 15s | 3 | G5 |
| Test of a core module changed | 38s | 6 | M6 |
| James change in a module every TMail module uses | 30s | 9 | M4, T2 P5 |
| Library upgraded by a James bump, used by every module | 35s | 9 | G17 |

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
| Today's stages, cache added to `tmail-backend/` | **Test stage runs 0 tests and passes** (outputs moved aside by the cache-enabled run); delivery fails | T1 |
| Proposed: Compile as today, Test `clean install`, Unstable Tests and delivery cache off | Compile never touches the cache; James tests never run; on another agent the Test stage restores all and runs 0 tests; the unstable test still runs; the image holds classes and glowroot files; a transitive James change and a broken Scala change fail the Test stage | T2 |
| Variant: Compile builds James only | Same cache behaviour as T2; a James change only `ai-bot` uses rebuilds and retests `ai-bot` only | T3 |
| Release tag, cache off | Everything built and tested; no lookup; nothing written; image complete | T4 |

## Jenkins

The multibranch job of [`tmail-sample/Jenkinsfile`](../tmail-sample/Jenkinsfile), against the cache server, on a fresh Jenkins.
Durations are whole pipelines (Compile, Test, Unstable Tests, delivery).

| Build | Duration | Test stage | Notes |
|---|---|---|---|
| master #1, cold | 125s (with dependency downloads) | 9 tests, 5 entries saved | 5 modules fingerprinted first; entries verified by the cleanup job before the next build |
| `feature-x`, `ai-bot` change | 25s | `ai-bot` only, 3 tests | writes nothing |
| master #2, no change | 25s | all restored, 0 tests | unstable test still runs; image complete |
| master #3, `IGNORE_BUILD_CACHE` (nightly path) | 43s | 9 tests | cache neither read nor written, no fingerprint step |
| tag `v1.0.0` | 43s | 9 tests | cache neither read nor written; image delivered |

The fingerprint step takes about 5s in the Jenkins container (three short Maven runs, measured separately). Master #2 took
15s in an earlier run without it; the rest of the difference is load from other builds on the machine.

No local cache is left on the agent afterwards.

## Problems found during the triage (fixed)

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

## Not covered

- TMail itself: real hit rate, entry sizes, restore and upload times, jib `buildTar` cost on fully cached builds, the
  fingerprint step on CI agents (run on a copy of TMail on a laptop only).
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

# Self-hosted Maven build cache: design proposal

Status: proposal, validated in this playground (results in [triage.md](triage.md)) and reviewed in several rounds by Codex
(gpt-6.1-sol, xhigh); the review's findings are fixed or listed in section 10.
First target: the TMail backend CI (`linagora/tmail-backend`, Jenkins). The cache server is shared: other Linagora Java
projects (Twake Calendar side service...) can use it later; how they adopt it is out of scope here.

## 1. Context and goal

- The TMail master build takes over 3 hours (build #1295: 3h18m, of which the `Test` stage took 2h48m).
- Apache James gets build caching from Develocity, which is commercial. The ASF gets it for free; Linagora would not.
  Develocity's Maven extension only reads the remote cache of a Develocity server, so its free cache node does not help.
- Goal: a free, self-hosted "Develocity-lite" for Maven, starting with the part that saves time:
  **a build cache shared by all CI builds, which skips a TMail module (compile and tests) when nothing it depends on changed.**
  Build timelines and dashboards come later (section 9).
- Scope: **TMail modules only.** James is built as today and is neither cached nor tested by TMail CI.

## 2. First principle: when in doubt, rebuild

A cache miss costs minutes. A wrong cache hit can hide a failing test or ship a stale artifact, and nobody notices.
So every choice below favours correctness over hit rate:

- A cache entry is only reused when we are sure it matches: same sources, same POMs, same dependencies (James included),
  same JDK, **and the tests really ran and passed** in the build that saved it.
- Anything the cache cannot see is either added to the key, or forces a rebuild, or is covered by a regular build that does not
  use the cache. What remains is listed as residual risk (section 10).
- **Releases never depend on the cache**: tag builds build and test everything from source, as today.
- The cache is disposable: losing it makes builds slower, never broken.

## 3. Architecture

```
                         Jenkins agents
   ┌──────────────────────────────────────────────────────────┐
   │ TMail pipeline                                           │
   │  Compile  (root: James + TMail)      no cache, as today  │
   │  Test     (tmail-backend/)           cache  ◄── .mvn/ in │
   │           maven-build-cache-extension 1.3.0  tmail-backend│
   │           local cache: $WORKSPACE/.build-cache (wiped)   │
   └──────┬────────────────────────────┬──────────────────────┘
          │ GET/HEAD                    │ PUT, master only,
          │ (all builds but tags        │ TMail's writer credential
          │  and nightly)               │
          ▼                             ▼
   ┌──────────────────────────────────────────────────────────┐
   │ nginx (http_dav_module), shared by projects              │
   │  /tmail/v1.2/<groupId>/<artifactId>/<key>/...            │
   │  /twake-calendar/...      (later)                        │
   │  GET/HEAD: open on the internal network, verified only   │
   │  PUT: writer credential of that project, new files only  │
   │  disk volume + cleanup job (verify, evict) every minute  │
   └──────────────────────────────────────────────────────────┘
```

| Component | Role | Custom code? |
|---|---|---|
| [Apache Maven Build Cache Extension](https://maven.apache.org/extensions/maven-build-cache-extension/) 1.3.0 | Computes each module's key, looks it up (local, then remote), restores the outputs and skips the module's work on a hit, uploads on a miss | No, configuration only |
| nginx with `http_dav_module` | Stores and serves files by path: GET, HEAD, PUT. One folder and one writer credential per project | No, a config file |
| Jenkins | Decides who reads and who writes (section 7) | Jenkinsfile changes |
| Cleanup job | Verifies new entries (only verified ones are served), deletes expired, incomplete and inconsistent ones | A shell script |

No cache server has to be written. The extension does all the logic; the server is plain file storage.

### Scope: only TMail modules use the cache

Maven loads extensions from the `.mvn/` folder of the directory it starts from. The extension and its configuration live
in `tmail-backend/.mvn/`, not at the repository root, so:

- the Compile stage (Maven from the root: James and TMail) runs exactly as today, without the extension;
- the Test stage (Maven from `tmail-backend/`) uses the cache, for TMail modules only.

In the Test stage, James modules are outside the reactor: they come as jars from `~/.m2`, installed by the Compile stage.

### What happens for each module

1. The extension computes the module's key: a hash of its inputs (section 4).
2. It looks for `<key>/buildinfo.xml` in the local cache, then on the remote cache
   (`<url>/v1.2/<groupId>/<artifactId>/<key>/buildinfo.xml`, `<url>` being `https://<host>/tmail`). The server only serves it once
   its cleanup job has verified the entry (G15): until then, it is a miss.
3. **Hit**: it downloads the stored files and skips every plugin execution of the module, compile and tests included,
   except those configured to always run. By default only the jars come back; with `<attachedOutputs>`, `target/classes`
   and `target/test-classes` too (needed by TMail, G10).
4. **Miss**: before building, it moves the outputs already in `target/` to a staging folder, so that nothing stale gets saved.
   Then the module is built normally. If saving is enabled and the module succeeded, it uploads the files, then `buildinfo.xml`
   last. A failed module is never saved. A rejected upload is logged and does not fail the build.
5. If a restore fails (a file missing on the server), the module is built normally; the next master build uploads the missing files.
6. After a remote miss, the extension does not look that key up again on the remote for a while (1 minute, then 1 hour, then 1 day):
   that errs towards rebuilding.

## 4. What the cache key contains

Read from the 1.3.0 sources (`MavenProjectInput`, `DefaultNormalizedModelProvider`), confirmed by the triage.

**What the extension hashes by default**

- Files under `src/main/java`, `src/test/java` and the resource folders.
- From the effective POM, only: coordinates, modules, dependencies and build plugins (with their configuration).
  **Not** properties, `dependencyManagement`, resource settings (filtering, includes) or anything else.
- For each dependency **in the same reactor** (other TMail modules): that module's key, so a change invalidates everything downstream,
  even when only tests changed (M6).
- For each SNAPSHOT dependency **outside the reactor**: the hash of the jar the module **declares**. Not the jars it gets
  transitively.
- External release dependencies: only their version, as written in the dependencies.

**What the proposed configuration adds**, so that the key covers what the build actually depends on:

| Added to the key | How | Why | Guard |
|---|---|---|---|
| Every file under `src/`, hidden files included | Global include `src/` (`includeHidden`) | `src/main/scala` (14 TMail modules) and `src/test/scala` (7) are not scanned by default | G2 |
| The module's `pom.xml` and every parent `pom.xml` up the tree | Global includes `pom.xml`, `../pom.xml` ... `../../../../../pom.xml` | Properties, `dependencyManagement` (transitive versions) and resource settings are not in the default key. Any change in a parent pom rebuilds every module below it | G14 |
| What each module gets from outside the reactor | Before the Test stage, [`ci/build-cache-fingerprint.sh`](../tmail-sample/ci/build-cache-fingerprint.sh) writes each module's dependency tree to `<module>/.build-cache-key/classpath.txt`: James jars with their SHA-256, transitive and test ones included, and every library with its version. The config hashes that folder | James is outside the Test stage reactor and the extension only hashes the jars a module declares: a change in a James module TMail gets transitively, or a library version James manages, would go unnoticed. With the fingerprint, a James bump only rebuilds the modules using what changed | G13 |
| The exact JDK, vendor and version | `build.cache.jdk = ${java.vendor} ${java.version}`, same mechanism | A JDK update, even minor, or another vendor | G3 |
| The Test stage's Maven flags | The executed pipeline repeats them in `-Dbuild.cache.ci.flags=...`, put into the surefire configuration in `tmail-backend/pom.xml` | Properties passed with `-D` are not in the key. For fork PRs, Jenkins runs the target branch's Jenkinsfile while the workspace may hold an older one, so the flags must come from the executed pipeline | G16 |
| The workspace Jenkinsfile | Global includes `../Jenkinsfile` ... `../../../../../Jenkinsfile` | Conservative extra: any change to the pipeline file rebuilds everything | G16 |
| Folders outside `src/` that the build packages | Global include `sample-configuration/` | TMail's `apps/postgres` image contains it | Audit |

Values that change legitimately between CI builds (JDK, CI flags, the James jars) must be in the key, not in a `reconcile` check:
a reconcile mismatch rebuilds the module but cannot save the result (same key, and the server refuses overwrites),
so the module would be rebuilt on every build until the old entry expires.

Keys depend on where Maven starts: the same module gets a different key in a build from the root (James in the reactor) and
from `tmail-backend/` (James as jars). The Test stage must always run from `tmail-backend/`.

**Still not in the key**: the content behind a Docker image tag (Testcontainers images, jib base image; pinning by digest puts it in
the key, as the sample does for its base image), `-D` overrides outside the Jenkinsfile, external services, time, randomness.
See G9 and section 10.

## 5. Defensive configuration

Configuration: [`tmail-sample/tmail-backend/.mvn/maven-build-cache-config.xml`](../tmail-sample/tmail-backend/.mvn/maven-build-cache-config.xml)
and the `build.cache.*` properties of [`tmail-sample/tmail-backend/pom.xml`](../tmail-sample/tmail-backend/pom.xml).
Each guard has a triage scenario that runs with the guard and without it.

| # | Risk | Guard | Proven by |
|---|---|---|---|
| G1 | An entry saved by a build that skipped, filtered or ignored tests is reused as if tests had passed | `reconcile` on surefire and failsafe for every way to skip or select tests: `skip`, `skipExec`, `skipTests`, `testFailureIgnore`, `test`, `includes`, `excludes`, `includesFile`, `excludesFile`, `groups`, `excludedGroups`, JUnit 5 engine filters, `skipAfterFailureCount`. A build that ran the tests may serve one that skips them, never the reverse. And only master saves, with a fixed command line | G1a, G1b |
| G2 | A change in a source root the extension does not scan is ignored | Global include `src/` | G2 |
| G3 | An entry built on another JDK is reused | Exact JDK in the key | G3 |
| G4 | An entry is saved from a dirty `target/` | `mandatoryClean=true`: only builds that ran `clean` are saved (CI must not pass `-Dmaven.clean.skip`) | G4 |
| G5 | Files produced as a side effect are missing on a hit: the jib image tar read by path by deployment tests, and what jib adds from `target/` | `runAlways` for jib `buildTar` and for the executions preparing its extra directories (TMail: `copy-glowroot-resources`, and the `download-maven-plugin` executions for glowroot, async-profiler and curl) | G5, M2 |
| G6 | `install` is skipped on a hit, so `~/.m2` lacks the jars for a later Maven run (jib delivery with `-pl`) | `runAlways` for `maven-install-plugin:install` | M2 |
| G7 | Cache poisoning: a PR build, a leaked credential, or another project writes entries that TMail later trusts | Only the master job saves; nginx rejects PUT without that project's writer credential; one credential per project folder; nginx refuses to overwrite an existing file (409), and serializes writes to the same path, so two concurrent PUTs cannot overwrite each other | G7 |
| G7b | Poisoning through an agent's local cache shared by builds | CI keeps the local cache in the workspace (`-Dmaven.build.cache.location=$WORKSPACE/.build-cache`), wiped by `deleteDir()` | Jenkins e2e |
| G8 | Cache server down or slow | Nothing to do: builds continue without the cache | O1 |
| G9 | Something outside the key changed (Docker image, external service), or a flaky test passed once and got cached | Pin Docker images by digest (the sample pins its jib base image): the digest is then in the key. Nightly master build with the cache off for the rest. If it fails while master is green, purge TMail's folder on the server (the cache is disposable) | Jenkins e2e |
| G10 | A hit restores jars only, but later stages use `target/classes` (jib) and `target/test-classes` (Unstable Tests) | `<attachedOutputs>` stores and restores `classes` and `test-classes` | T2, G5 |
| G11 | A Maven run with the cache on moves the existing `target/` outputs aside: a stage reusing what an earlier stage left there finds nothing. A `surefire:test` stage then **passes with 0 tests**, a jib stage fails | Stages that reuse `target/` (Unstable Tests, Deliver) run with `-Dmaven.build.cache.enabled=false`. The Test stage itself is a full `clean install` | T1 |
| G12 | A release image depends on cache state | Tag builds run with the cache off: nothing read, nothing written, everything built and tested from source | T4, Jenkins e2e |
| G13 | A James bump changes code or a library version a TMail module uses, transitively, while the jars it declares stay identical: its key would not change | Per-module fingerprint of the dependency tree (James jars by content, libraries by version). It relies on James jars being reproducible, which holds on real James (see [estimate.md](estimate.md)) | G13, G17, M5, M8, T2 |
| G14 | A change in properties, `dependencyManagement` or resource settings of a pom leaves the keys unchanged | Module and parent poms hashed | G14 |
| G15 | An interrupted upload leaves an incomplete entry, or one later completed by another build of the same key (files of one build, metadata of another) | nginx only serves an entry once the cleanup job, every minute, has checked its files against the SHA-256 hashes of its `buildinfo.xml`: an inconsistent entry is deleted before anyone can restore it. Uploads left without `buildinfo.xml` are deleted after a day. A file lost after verification only fails the restore: the module is rebuilt, and master (saving without `remote.save.final`) uploads the missing file again | O2, O3, O4 |
| G16 | A CI flag (`-D...`) changes what the build produces without changing the key | The executed pipeline repeats the Test stage flags in `build.cache.ci.flags` (in the key); the workspace Jenkinsfile is hashed too | G16 |

## 6. Cache server: nginx, shared by projects

Config: [`cache-server/nginx.conf`](../cache-server/nginx.conf).

- **One folder per project**: `/tmail/`, later `/twake-calendar/`... A project points its extension at `https://<host>/<project>`.
- **One writer credential per project**: `htpasswd.d/<project>`. TMail's CI cannot write into another project's folder (401);
  a folder without a credential file cannot be written at all (403).
- **Reads are open** on the internal network: fine for open-source code like TMail, since entries only hold its build outputs.
  A private project would also need read authentication on its folder (`auth_basic` for GET in nginx, a reader credential in its CI).
- **Immutable entries**: a PUT on an existing file answers 409; DELETE is not allowed. These rules sit at server level on purpose:
  inside a `location` holding `limit_except`, nginx skips `if`/`set` rules for PUT (found during the triage: the rule was silently
  ignored). The existence check runs before the upload, so nginx also allows a single PUT at a time per entry (`limit_conn`, keyed
  on the 64-character entry folder: nginx ignores keys over 255 bytes, which full paths can exceed). A second PUT on an entry being
  written answers 409. A residual race remains (section 10).
- **Only verified entries are served**: a GET on a `buildinfo.xml` answers 404 until the cleanup job has verified the entry
  (`.verified` marker). The extension reads that as a miss. Uploading a dot-file is refused (403), so nobody but the cleanup job can
  write that marker, and an entry holding a file newer than its marker is verified again.
- `create_full_put_path on`: a PUT creates the folders (no MKCOL). A missing entry answers **404**: the extension reads 403 as an
  error, not as a miss.
- Uploads land in a temporary folder on the same volume, then are renamed into place: a reader never sees a half-written file.
- **Cleanup**: [`cache-server/evict.sh`](../cache-server/evict.sh), every minute, entry by entry: new entries are verified
  against the SHA-256 hashes in their `buildinfo.xml` and then served (an inconsistent one is deleted, O4); an entry whose newest file
  is older than 21 days is deleted as a whole; an entry without `buildinfo.xml` older than a day (an upload that never completed) too.
  Deleting by age is safe: an entry still in use is rebuilt once and saved again (O3). A new entry is served within about a minute
  of its upload.
- **Sizing** (to measure on TMail): only TMail modules are stored, each entry holding the module jars plus zipped
  `classes` and `test-classes`. A James bump writes new entries for the modules using what it changed, a parent pom change for every
  module below it.
- **No backup**: losing the volume only costs slower builds until the entries are saved again.
- **Placement**: same network as the Jenkins agents; a hit downloads the stored files.

Onboarding another project later (not covered by this triage): add `htpasswd.d/<project>`, give its CI the credential,
add the extension and a configuration to that project with the URL `https://<host>/<project>`, then go through the guards of section 5
and the inputs of section 4 for that project (what it gets from outside its reactor, what it packages from outside `src/`).

## 7. Jenkins pipeline for TMail

Today: `Compile` runs `mvn clean install -DskipTests -T1C` from the root, `Test` runs `mvn surefire:test` from `tmail-backend/`,
`Unstable Tests` runs `surefire:test -Punstable-tests`, the delivery stages run `jib:build` per app.

**Today's stages cannot simply be kept with the cache** (T1): the `surefire:test` stage, run with the cache on, moves the compiled
tests aside and passes with 0 tests; the delivery fails. The Test stage has to become a lifecycle build.

### Who uses the cache

| Build | Cache | Why |
|---|---|---|
| master push | read + write | The only writer: entries come from reviewed code |
| branch, PR | read only | A PR cannot write; no credential bound |
| tag (release) | off | A release never depends on cache state (G12) |
| nightly master (timer) | off | Catches what the key cannot see (G9) |
| manual `IGNORE_BUILD_CACHE=true` | off | Escape hatch |

### Option A: keep today's split (validated: T2, Jenkins e2e)

| Stage | Command | Cache |
|---|---|---|
| Compile | root: `mvn clean install -DskipTests -T1C` (unchanged) | none |
| Test | `tmail-backend/`: `ci/build-cache-fingerprint.sh com.linagora.tmail <the stage's settings and flags>`, then `mvn clean install` (**was** `surefire:test`) | read; master writes |
| Unstable Tests | `tmail-backend/`: `mvn surefire:test -Punstable-tests -Dmaven.build.cache.enabled=false` | off |
| Deliver | `tmail-backend/`: `mvn -Pci jib:build -pl apps/... -Dmaven.build.cache.enabled=false` | off |

Cost: a changed TMail module is compiled twice per pipeline (Compile, then Test after `clean`). Unchanged modules are restored in the
Test stage, compiled classes included.

### Option B: Compile builds James only (validated in the sample: T3, with a caveat)

Same as A, but the Compile stage only builds what TMail needs from outside `tmail-backend/`: the root pom, `james-project`,
`logback-contrib` (in the sample: `mvn -N install` at the root, then `mvn clean install -DskipTests` in `james-project/`).
TMail is then compiled once, in the Test stage. Compile errors in TMail show in the Test stage instead.

**Caveat for TMail**: running Maven from `james-project/` loads James's own `.mvn/extensions.xml`, i.e. Develocity, with its remote
cache and build scans. The sample's James has no `.mvn/`, so T3 does not show it. Option B would have to turn Develocity off
explicitly (tags included), or build James from the root with a module selection. Option A has no such issue.

The cache behaves the same in both options: the Test stage does not depend on what the Compile stage built, and the fingerprint
step only needs James installed (it collects dependency trees, it does not need TMail's modules built).
A single Maven run from the root is not an option: it would run the James test suite.

### Pipeline details (sample: [`tmail-sample/Jenkinsfile`](../tmail-sample/Jenkinsfile))

- Cache options of the Test stage: `-Dmaven.build.cache.enabled=false` for tags, nightly and `IGNORE_BUILD_CACHE`; otherwise
  `-Dmaven.build.cache.remote.url=https://<host>/tmail -Dmaven.build.cache.location=$WORKSPACE/.build-cache
  '-Dbuild.cache.ci.flags=<the Test stage flags>'`, plus
  `-Dmaven.build.cache.remote.save.enabled=true` and the writer credential (through `withCredentials`) on master only.
- **The Test stage flags are defined once** (`testStageFlags()` in the sample Jenkinsfile, TMail: `-Dapi.version=1.43`) and passed both
  to Maven and in `build.cache.ci.flags`, so the key follows the pipeline actually executed (G16).
- **The fingerprint step must run before every cache-enabled Test stage**, with the same settings and flags as the stage:
  without `.build-cache-key/`, G13 is gone. The script fails, and the stage with it, when Maven fails, when a James SNAPSHOT jar
  of a dependency tree is missing from the local repository or cannot be hashed, when a tree line is not understood, or when a
  module (a `pom.xml` below `tmail-backend/`) got no fingerprint. It hashes the James jars of the local repositories Maven
  reports for the same arguments (settings and `.mvn/maven.config` included): those the Compile stage installed, as long as no
  remote repository serves newer James SNAPSHOTs (otherwise run both offline). `.build-cache-key/` is git-ignored;
  the step took about 20 s on a laptop on TMail (96 modules), dependencies already downloaded.
- TMail tees the Test stage output to `ci-logs` before Jenkins masks secrets. On master, where the writer credential is in the
  environment, run the Test stage outside `tee` (failure reports are posted to pull requests, which have no credential).
- Fork PRs run the Jenkinsfile of the target branch, so a PR cannot change who gets the credential. Add `tmail-backend/.mvn/` to the
  Jenkinsfile's `protectedCiPaths()`, next to the root `.mvn/`.
- The `junit` step of the Test stage needs `allowEmptyResults: true`: when every module is a hit, no report exists.
- `-T1C` (parallel builds) was not covered by the triage: to check on TMail.
- Cost to measure: with `runAlways` on jib `buildTar` (G5), the Test stage rebuilds each app's image tar even when every module is a
  hit. TMail builds several apps; if that dominates a fully cached Test stage, the tars could instead be built only when the
  deployment tests are not restored.

## 8. Triage

`tmail-sample/` mirrors TMail's layout and stages (see [its README](../tmail-sample/README.md)). `scripts/triage.sh` runs 27 scenarios,
each from an empty cache and fresh agents; `scripts/jenkins-e2e.sh` runs the pipeline in Jenkins (master, branch, nightly-like and
tag builds). Results: [triage.md](triage.md).

## 9. Later: the rest of "Develocity-lite"

Only once the cache proves itself on TMail:

- Build timelines: OpenTelemetry Maven extension, exported to Grafana Tempo.
- Test history and flaky tests: ReportPortal, or the Jenkins JUnit plugin history.
- Cache dashboard (hit rate, time saved, top miss reasons): the extension uploads a `build-cache-report.xml` per build
  next to the entries; a small job can turn them into Prometheus metrics.
- Test distribution across agents: Jenkins Parallel Test Executor plugin.

## 10. Residual risks and open questions

Known limits of this setup, accepted for a proof of concept:

- **The James fingerprint relies on reproducible James jars.** Verified on three real James modules (Java, Scala, test jars). A James
  module that is not reproducible only makes the TMail modules using it rebuild every time: safe, no saving. Caching James's own
  compile in the Compile stage would keep restored James jars identical anyway.
- **Mutable Docker image tags** (Testcontainers images, jib base image): unless pinned by digest, the key holds the tag, not the
  content. The POC must audit TMail's (and the James test helpers') images for floating tags and pin them; the nightly cache-off build
  detects the rest, a day late.
- **The extension does not verify restored files itself**: the server does, before serving an entry (G15). A file corrupted on disk
  after verification without a newer modification time would be served; the volume is the trust boundary.
- **nginx cannot create a file atomically "if absent"**: the existence check runs before the per-entry write lock. Two uploads of the
  same entry, the second admitted in the microseconds between the first one finishing and its own lock, could replace a file, even
  after verification. The cleanup job sees the newer file within a minute and deletes the entry if it no longer matches; until then it
  could be served. It takes two master builds of the same inputs at the same moment, which a single writer job with
  `disableConcurrentBuilds()` does not produce. A complete fix needs a store with atomic conditional writes: a small write service,
  or an object store supporting `If-None-Match: *` behind a thin proxy.
- **`-D` overrides that the pipeline does not repeat in `build.cache.ci.flags`** (a developer's command line, or a flag added to the
  Test stage without updating `testStageFlags()`) are not in the key. Only CI writes; developers reading the cache would need the same
  discipline.
- **Test selection files** (`includesFile`, `excludesFile`): their path is tracked, not their content. CI does not use them.
- **Inputs outside `src/` read by tests** in TMail (beyond the jib tars and `sample-configuration/`): to audit during the POC.

Open questions for the TMail proof of concept:

- Real hit rate, sizes and timings (restore time of large modules, upload time on master, jib `buildTar` cost on full hits,
  fingerprint step). Replaying TMail's history gives 50 to 78 minutes of test work skipped per master build on average (gross,
  before overheads), against 35 to 53 with the James revision in the key: see [estimate.md](estimate.md).
- `-T1C` with the cache in the Test stage.
- Option A or B for the Compile stage.
- Who hosts the nginx instance and holds the writer credentials.

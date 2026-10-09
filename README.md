# Java build cache playground

Feasibility study for a free, self-hosted Maven build cache, a "Develocity-lite" for Linagora's Java CI.
First target: the [TMail backend](https://github.com/linagora/tmail-backend) CI, whose build takes over 3 hours,
mostly tests. Idea: skip compiling and testing a TMail module when nothing it depends on changed,
without ever trusting a result we are not sure about.

- Design proposal: [docs/design.md](docs/design.md)
- Triage results: [docs/triage.md](docs/triage.md), generated tables in [docs/triage-report.md](docs/triage-report.md)
  and [docs/jenkins-e2e-report.md](docs/jenkins-e2e-report.md)
- Expected savings on TMail, from its real history: [docs/estimate.md](docs/estimate.md)
- Reviewed in several rounds by Codex (gpt-6.1-sol, xhigh and high): findings are fixed or listed as residual risks in the
  design (section 10)

## Decision (2026-10-09): not adopted for TMail for now

The setup works and is validated, but for TMail today it does not pay for its complexity:

- **The gain shrank.** TMail's own optimizations brought the build to about 1h15, with the Test stage as two parallel branches
  (about 55 minutes). The stage lasts as long as its slower branch, usually the JMAP integration suites, which depend on almost
  everything and would still rerun on about 84% of master builds. Roughly 10 minutes saved on average, often nothing on a
  typical build, before the cache's own overheads (changed modules compiled twice, jib image tars rebuilt, fingerprint step).
- **The cost stays.** About 20 guards, a fingerprint script, a copy of the sources for one Test branch, a private local
  repository per pipeline, a root pom change, Jenkinsfile changes and a cache server to run. Its failures are silent: a guard
  missed after a routine change (a new app packaging files from `target/`, a test reading a file outside `src/`, a new CI flag,
  a module outside `tmail-backend/`, a floating Docker tag, a reshaped Jenkinsfile) gives green builds whose tests did not run.
  The triage kept finding such cases, some introduced while building this setup.

Revisit when the JMAP integration suites stop being the bottleneck of most builds, when the build grows back towards several
hours, or for a project whose modules are more independent (the server and the guards are generic). A much cheaper step for
TMail meanwhile: skip the Test stage when a commit only touches documentation, or when the same source tree already passed on
master.

## Result in short

- **It works with off-the-shelf parts**: the Apache Maven Build Cache Extension and a plain nginx. No server code.
  Same commit on another agent: TMail's Test stage restores every module and runs no test.
- **Only with defensive guards**: with the extension defaults, the cache reuses builds that skipped or excluded tests,
  ignores changes to Scala sources, the JDK, parent poms, CI flags and James modules TMail only gets transitively, breaks jobs
  that read build outputs by path, and, with the Test stage split in two `-pl` builds, misses changes made in the other split.
  Each risk is reproduced by the triage, and each guard proven. The limits that remain are listed in the design (section 10).
- **TMail's Jenkinsfile needs changes** (it now runs the Test stage as two parallel branches): each branch becomes a
  `clean verify` build instead of `surefire:test`; the other modules' branch runs on its own copy of the sources, or its `clean`
  would delete the app images the deployment tests load; a new step writes the fingerprints first; the stages reusing `target/`
  (Unstable Tests, Docker delivery) and the cache-off builds run with the cache off. Kept as is, the Test stage would pass with
  0 tests.
- **TMail's root pom needs `project.build.outputTimestamp`**: the Compile stage rebuilds `logback-contrib` every time, and its
  jars differ from one build to the next; the apps declare them, so the apps and the JMAP and deployment tests would never be
  restored.
- **Scope**: TMail modules only. James is built as today, never cached, never tested. A James bump only retests the TMail modules
  whose dependency tree holds a James jar it changed (James jars are reproducible, so unchanged ones keep their hash).
- **Estimated gain**: a replay of TMail's history skips about half of the test work per master build on average
  ([docs/estimate.md](docs/estimate.md), written for the former sequential Test stage). With the two parallel branches, the
  stage lasts as long as its slower branch, usually the integration one, which a change still reaches on most builds: roughly
  10 minutes saved on average on today's ~55-minute Test stage, much more when a change does not reach the JMAP suites, nothing
  on full rebuilds (James root pom bumps, nightly, tags).
- **Shared server**: one folder and one writer credential per project, so other Java projects can use the same server later.

## How it works

- **Client**: the [Apache Maven Build Cache Extension](https://maven.apache.org/extensions/maven-build-cache-extension/) 1.3.0,
  declared in `tmail-backend/.mvn/extensions.xml`, so only builds started from `tmail-backend/` use it.
- **Server**: nginx with its WebDAV module ([cache-server/nginx.conf](cache-server/nginx.conf)). Anyone on the network can read;
  each project's CI writes into its own folder with its own credential; files cannot be overwritten (concurrent uploads of one
  entry are serialized; the narrow race left is described in the design, section 10); an entry is only served once a cleanup job,
  running every minute, has checked its files against their recorded hashes ([cache-server/evict.sh](cache-server/evict.sh)).
- **Policy**: master writes; branches and PRs read; tag (release) and nightly builds don't use the cache.
- **Guards**: [tmail-sample/tmail-backend/.mvn/maven-build-cache-config.xml](tmail-sample/tmail-backend/.mvn/maven-build-cache-config.xml)
  and the `build.cache.*` properties of [tmail-sample/tmail-backend/pom.xml](tmail-sample/tmail-backend/pom.xml) force a rebuild
  in every case the triage reproduced.

## Layout

| Path | What |
|---|---|
| `docs/` | Design, triage summary, generated reports |
| `cache-server/` | nginx config, per-project writer credentials (dev only: `tmail-ci` / `tmail-ci-password`), eviction script |
| `docker-compose.yml` | Cache server on `:8090`; Jenkins on `:8085` with the `jenkins` profile |
| `jenkins/` | Jenkins image: Maven, plugins, configuration as code (multibranch job `tmail-sample`) |
| `tmail-sample/` | Small build shaped like the TMail repository, with TMail's Jenkinsfile stages ([mapping](tmail-sample/README.md)) |
| `scripts/triage.sh` | Runs the triage scenarios against the cache server |
| `scripts/jenkins-e2e.sh` | Runs the pipeline in Jenkins: master, branch, nightly-like and tag builds |
| `scripts/configs/` | The extension defaults, used by the triage to show each risk without its guard |
| `scripts/estimate-tmail-savings.py` | Replays a TMail checkout's master history to estimate the Test stage time saved |
| `work/` | Generated: dependency cache, agents, logs, reports (git-ignored) |

## Run it

Needs Docker, Maven 3.9+, JDK 25 and JDK 21 (for the JDK scenario), and network access.

```bash
docker compose up -d          # cache server on http://localhost:8090 (TMail's folder: /tmail)
scripts/triage.sh             # every scenario (~1 hour), or a few: scripts/triage.sh M2 G2 T2
scripts/jenkins-e2e.sh        # starts Jenkins (http://localhost:8085, admin / admin) and runs the pipeline
docker compose --profile jenkins down    # stop everything (add -v to drop the cache and Jenkins volumes)
```

Reports land in `work/triage/results.md` and `work/jenkins-e2e/results.md`; the copies in `docs/` are from the last run.
Don't run the two scripts at the same time: the triage empties the cache between scenarios.
To try the sample by hand, see [tmail-sample/README.md](tmail-sample/README.md).

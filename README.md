# Java build cache playground

Feasibility study for a free, self-hosted Maven build cache, a "Develocity-lite" for Linagora's Java CI.
First target: the [TMail backend](https://github.com/linagora/tmail-backend) CI, whose build takes over 3 hours,
mostly tests. Idea: skip compiling and testing a TMail module when nothing it depends on changed,
without ever trusting a result we are not sure about.

- Design proposal: [docs/design.md](docs/design.md)
- Triage results: [docs/triage.md](docs/triage.md), generated tables in [docs/triage-report.md](docs/triage-report.md)
  and [docs/jenkins-e2e-report.md](docs/jenkins-e2e-report.md)
- Expected savings on TMail, from its real history: [docs/estimate.md](docs/estimate.md)
- Reviewed in several rounds by Codex (gpt-6.1-sol, xhigh): findings are fixed or listed as residual risks in the design (section 10)

## Result in short

- **It works with off-the-shelf parts**: the Apache Maven Build Cache Extension and a plain nginx. No server code.
  Same commit on another agent: TMail's Test stage restores every module and runs no test.
- **Only with defensive guards**: with the extension defaults, the cache reuses builds that skipped or excluded tests,
  ignores changes to Scala sources, the JDK, parent poms, CI flags and James modules TMail only gets transitively, and breaks jobs
  that read build outputs by path. Each risk is reproduced by the triage, and each guard proven. The limits that remain are listed
  in the design (section 10).
- **TMail's Jenkinsfile needs small changes**: the Test stage becomes `clean install` instead of `surefire:test`, and the stages
  reusing `target/` (Unstable Tests, Docker delivery) run with the cache off. Kept as is, the Test stage would pass with 0 tests.
- **Scope**: TMail modules only. James is built as today, never cached, never tested. A James bump only retests the TMail modules
  whose dependency tree holds a James jar it changed (James jars are reproducible, so unchanged ones keep their hash).
- **Estimated gain** on TMail's 2h48 Test stage: about 50 to 80 minutes of test work skipped per master build on average
  (gross, before the cache's own overheads), from a replay of its history through the cache rules, with test times from a
  laptop; the slow JMAP integration suites still rerun on most builds ([docs/estimate.md](docs/estimate.md)).
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

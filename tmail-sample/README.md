# tmail-sample

A small Maven build shaped like the [TMail backend](https://github.com/linagora/tmail-backend) repository,
to try the build cache on TMail's structure and CI stages without TMail's 3-hour build.
Tests sleep a few seconds each, to stand for TMail's slow tests.

## What each part stands for

| Here | In TMail | Why it matters for the cache |
|---|---|---|
| `pom.xml` | Root `pom.xml` (`tmail-backend-parent`), aggregating `james-project` and `tmail-backend` | The Compile stage builds from here. There is no `.mvn/` here, so this build never uses the cache |
| `james-project/` | The `james-project` submodule | Built by the Compile stage, never tested, never cached. A standalone build with its own parent, like James. Sets `project.build.outputTimestamp`, so its jars are reproducible |
| `james-project/james-core` | James modules TMail declares (mailbox API, server core...) | Calls `james-mailbox` at runtime; brings `commons-lang3`, whose version James's pom manages |
| `james-project/james-mailbox` | James modules TMail only gets transitively | Changing it leaves `james-core.jar` identical: only the per-module fingerprint of the dependency tree catches it (G13) |
| `james-project/james-mailet` | James modules only some TMail modules use | Only `ai-bot` uses it: changing it only rebuilds `ai-bot` (M8) |
| `tmail-backend/` | `tmail-backend/` | The Test stage builds from here. Its `.mvn/` enables the cache: TMail modules only. Its pom puts the exact JDK and the CI flags into every module's key (`build.cache.*` properties) |
| `tmail-backend/.mvn/` | Would be `tmail-backend/.mvn/` | Cache extension and its defensive configuration |
| `tmail-backend/jmap-extensions` | `tmail-backend/jmap/extensions` | Java and Scala sources (`src/main/scala`). Holds a test tagged `unstable` |
| `tmail-backend/ai-bot` | `tmail-backend/tmail-third-party/ai-bot` | A leaf module: changing it only rebuilds it. A resource filtered with a root pom property (`ai.bot.model`) stands for root pom properties and dependencyManagement (G14) |
| `tmail-backend/distributed-app` | `tmail-backend/apps/distributed` | jib `buildTar` bound to `package` writes `target/jib-image.tar`; jib packages `target/classes` and `target/glowroot`, prepared by `copy-glowroot-resources` in the same phase |
| `tmail-backend/integration-tests` | `integration-tests/jmap/*` and `deployment-tests` | Slow tests depending on everything; one loads `../distributed-app/target/jib-image.tar` by path |
| `ci/maven-settings.xml` | (new) | Writer credential for the cache, taken from the environment |
| `ci/build-cache-fingerprint.sh` | (new) | Run before the Test stage: writes each module's dependency tree, James jars hashed, to `.build-cache-key/` (G13) |
| `Jenkinsfile` | `Jenkinsfile` | TMail's stages with the cache on the Test stage; changes marked `CHANGE` |

Tests: 1 in James (never run by the pipeline), 9 stable ones in `tmail-backend/`, plus 1 tagged `unstable`
(excluded by default, run with `-Punstable-tests`, as in TMail's root pom).

## Build it

```bash
# Compile stage: James and TMail, no cache
mvn clean install -DskipTests
# Test stage: TMail modules, with the cache (reads http://localhost:8090/tmail, see ../docker-compose.yml).
# First the fingerprint of what each module gets from James, then the build
cd tmail-backend && ../ci/build-cache-fingerprint.sh com.linagora.tmail.sample && mvn clean install
```

To save to the cache, as the master job does:

```bash
cd tmail-backend
../ci/build-cache-fingerprint.sh com.linagora.tmail.sample -s ../ci/maven-settings.xml
BUILD_CACHE_USER=tmail-ci BUILD_CACHE_PASSWORD=tmail-ci-password \
  mvn -s ../ci/maven-settings.xml clean install -Dmaven.build.cache.remote.save.enabled=true
```

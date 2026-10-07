# Expected savings on TMail

How much of TMail's Test stage (2h48m in master build #1295) the cache would skip, estimated by replaying TMail's real
`master` history through the cache rules of [design.md](design.md). Script: [`scripts/estimate-tmail-savings.py`](../scripts/estimate-tmail-savings.py),
run on TMail `master` at `62f0a80b9`, pushes since 2026-07-01.

## Method

- **Builds**: TMail rebase-merges pull requests, so commits sharing a committer timestamp are one push, i.e. one master build:
  132 pushes.
- **What each push rebuilds**, following the cache key:
  - a change in the root pom, `tmail-backend/pom.xml`, the Jenkinsfile or `logback-contrib`: every module;
  - a parent pom: every module below it, and their dependents;
  - a module (outside `*.md`): that module and every module depending on it, from the dependency graph of the POMs;
  - a `james-project` bump, two strategies:
    - **revision**: the James revision is in every key, so every module is rebuilt;
    - **fingerprint** (the design's G13): each module's key holds the James jars of its own dependency tree, so only modules
      using a James module the bump changed are rebuilt (from the James submodule diff and each module's real `dependency:tree`);
      a change to James's root pom (library versions) rebuilds everything.
- **Modules counted**: at each push, only the modules existing then. The dependencies between modules and the James
  dependency trees are today's: the figures model today's structure on the past changes.
- **Weights**: the test time of each module. Jenkins needs a login, so the default is a proxy: surefire reports left in the
  TMail checkout by local runs (18 modules, mostly the heavy integration suites), and for other modules their number of test
  classes times the median time per class. Real CI numbers can be passed with `--durations`.

## Results

| Push type | Count | Rebuilt with the revision | Rebuilt with the fingerprint |
|---|---|---|---|
| No James bump | 69 | the changed modules and their dependents | same |
| James bump | 63 | every module | the modules using a changed James module (median 52 of 87 modules with code) |
| of which James's root pom changed | 10 | every module | every module |

Test work skipped, on average per master build, as a share of the Test stage (gross: overheads not subtracted, see below):

| Test time weighting | Revision | Fingerprint |
|---|---|---|
| Measured modules only (the heavy suites dominate) | 21% (35 min) | 30% (50 min) |
| Measured, plus test classes for the others (script default) | 31% (53 min) | 46% (78 min) |
| Test classes only | 28% (47 min) | 41% (69 min) |

The JMAP integration suites, which probably hold most of CI's test time, are rebuilt in 85 to 88% of master builds with the
revision and still 81 to 84% with the fingerprint: almost every TMail change and most James bumps reach something they depend on. The
fingerprint mostly helps the many smaller modules (`jmap/extensions` 61% → 43%, `mailets` 60% → 38%, `jmap/extensions-api`
55% → 30%). So the realistic figure is nearer the first row.

## What the figures leave out

- **Overheads**, not subtracted: on a miss, the Test stage now compiles and packages the TMail modules (today `surefire:test`
  reuses the Compile stage's classes); jib `buildTar` runs on every Test stage; the fingerprint step resolves the dependency
  trees (about 20 s on a laptop); a new entry is served once verified, within about a minute.
- **Pull request builds** are not counted. They behave like master builds of the same changes, but only reuse what master saved:
  pushing to a PR again does not reuse that PR's previous build.
- The weights come from a laptop, not from CI.

## Is the fingerprint sound on real James?

It needs unchanged James modules to give byte-identical jars, so that their hash does not change. James sets
`project.build.outputTimestamp`. Three James modules were built twice from clean in the TMail checkout, including the Scala
`server/protocols/jmap-rfc-8621`: all six jars, test jars included, were identical. A James module that is not reproducible would
only make the TMail modules using it rebuild every time (safe, but no saving); caching James's own compile would cure that.

## Refining the estimate

Get per-test-class durations of a recent master build from Jenkins (logged in):
`.../job/Tmail build/job/master/<build>/testReport/api/json?tree=suites[name,duration]`. Map each class to its module (the
module holding `src/test/**/<Class>.java` or `.scala`), sum per module into `{"tmail-backend/<module dir>": seconds}`, and run:

```bash
scripts/estimate-tmail-savings.py --tmail-repo ~/IdeaProjects/tmail-backend --durations durations.json
```

#!/usr/bin/env python3
"""Estimates how much of TMail's Test stage the build cache would skip, by replaying TMail's master history.

For every push to master (rebase-merged commits share a committer timestamp: one push, one master build), it decides which
tmail-backend modules the cache would rebuild, following docs/design.md:
- the root pom, tmail-backend/pom.xml, the Jenkinsfile or logback-contrib changed: every module;
- a parent pom changed: every module below it, and everything depending on them;
- a module changed (outside *.md): that module and every module depending on it;
- james-project bumped, two strategies:
    revision:     the James revision is in every key, so every module is rebuilt;
    fingerprint:  each module's key holds the James jars of its own dependency tree (ci/build-cache-fingerprint.sh), so only
                  modules using a James module the bump changed are rebuilt (a change to James's root pom, which manages
                  library versions, rebuilds everything).
The skipped share of the Test stage is then weighted by each module's test time, counting at each push only the modules
existing then. It is a model on today's structure: dependencies between modules and James dependency trees are today's.

Test time per module: by default a proxy (surefire reports found in the TMail checkout, from local runs, and for modules
without any, their number of test classes times the median time per class). Pass --durations with real CI numbers when
available: a JSON object {"tmail-backend/<module dir>": seconds}.

Reads the TMail checkout without modifying it: Maven writes the dependency trees to a temporary file, offline.
James must be installed in the local Maven repository (as after a TMail build).

Usage: scripts/estimate-tmail-savings.py --tmail-repo ~/IdeaProjects/tmail-backend [--since 2026-07-01]
                                          [--test-stage-minutes 168.8] [--durations durations.json]
"""
import argparse
import collections
import glob
import json
import os
import re
import statistics
import subprocess
import tempfile
import xml.etree.ElementTree as ET

NS = '{http://maven.apache.org/POM/4.0.0}'
TMAIL_GROUPS = {None, '${project.groupId}', 'com.linagora.tmail'}


def text(element, tag):
    child = element.find(NS + tag)
    return child.text.strip() if child is not None and child.text else None


def read_modules(root_dir, relative_to):
    """dir (relative) -> {artifactId, packaging, deps: [(groupId, artifactId)]}, dependencyManagement entries excluded"""
    modules = {}
    for pom in glob.glob(root_dir + '/**/pom.xml', recursive=True):
        if '/target/' in pom or '/src/' in pom or '/.claude/' in pom:
            continue
        try:
            root = ET.parse(pom).getroot()
        except ET.ParseError:
            continue
        managed = set()
        management = root.find(NS + 'dependencyManagement')
        if management is not None:
            managed = {id(dep) for dep in management.iter(NS + 'dependency')}
        deps = [(text(dep, 'groupId'), text(dep, 'artifactId'))
                for dep in root.iter(NS + 'dependency') if id(dep) not in managed]
        modules[os.path.relpath(os.path.dirname(pom), relative_to)] = {
            'artifactId': text(root, 'artifactId'), 'packaging': text(root, 'packaging') or 'jar', 'deps': deps}
    return modules


def deepest_module(path, module_dirs):
    best = None
    for d in module_dirs:
        if d != '.' and (path == d + '/pom.xml' or path.startswith(d + '/')) and (best is None or len(d) > len(best)):
            best = d
    return best


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--tmail-repo', required=True)
    parser.add_argument('--since', default='2026-07-01')
    parser.add_argument('--test-stage-minutes', type=float, default=168.8, help='Test stage duration (build #1295: 2h48m49s)')
    parser.add_argument('--durations', help='JSON {"tmail-backend/<module dir>": seconds} measured on CI')
    args = parser.parse_args()
    repo = os.path.abspath(os.path.expanduser(args.tmail_repo))
    james = os.path.join(repo, 'james-project')

    # ---- TMail modules and their dependents
    modules = read_modules(os.path.join(repo, 'tmail-backend'), repo)
    by_artifact = {m['artifactId']: d for d, m in modules.items()}
    dependents = collections.defaultdict(set)
    for d, m in modules.items():
        for group, artifact in m['deps']:
            if artifact in by_artifact and group in TMAIL_GROUPS and by_artifact[artifact] != d:
                dependents[by_artifact[artifact]].add(d)

    def with_dependents(start):
        result, stack = set(start), list(start)
        while stack:
            for nxt in dependents[stack.pop()]:
                if nxt not in result:
                    result.add(nxt)
                    stack.append(nxt)
        return result

    all_modules = set(modules)
    jar_modules = {d for d, m in modules.items() if m['packaging'] != 'pom'}

    def tmail_invalidated(files):
        rebuilt = set()
        for f in files:
            if f in ('pom.xml', 'tmail-backend/pom.xml', 'Jenkinsfile') or f.startswith('logback-contrib/'):
                return set(all_modules)
            if not f.startswith('tmail-backend/') or f.endswith('.md'):
                continue
            m = deepest_module(f, modules)
            if m is None:
                continue
            if f == m + '/pom.xml' and modules[m]['packaging'] == 'pom':
                rebuilt |= with_dependents({d for d in modules if d == m or d.startswith(m + '/')})
            else:
                rebuilt |= with_dependents({m})
        return rebuilt

    # ---- the James artifacts in each TMail module's dependency tree (offline, written to a temporary file)
    with tempfile.TemporaryDirectory() as tmp:
        tree_file = os.path.join(tmp, 'trees.txt')
        subprocess.run(['mvn', '-B', '-q', '-o', '-f', os.path.join(repo, 'tmail-backend', 'pom.xml'),
                        'dependency:tree', '-DappendOutput=true', f'-DoutputFile={tree_file}',
                        '-Dmaven.build.cache.enabled=false'],
                       check=True, env=dict(os.environ, MAVEN_SKIP_RC='true'))
        james_in_tree = collections.defaultdict(set)   # artifactId of a TMail module -> {(james artifactId, is tests jar)}
        current = None
        for line in open(tree_file):
            if not line.startswith((' ', '|', '+', '\\')):
                current = line.split(':')[1]
                continue
            coordinates = re.sub(r'^[-|+\\ ]+', '', line.strip()).split(' ')[0].split(':')
            if coordinates[0].startswith('org.apache.james'):
                is_tests = coordinates[2] == 'test-jar' or (len(coordinates) == 6 and coordinates[3] == 'tests')
                james_in_tree[current].add((coordinates[1], is_tests))

    james_modules = read_modules(james, james)

    def git(*arguments, cwd=repo):
        return subprocess.run(['git', '-C', cwd, *arguments], capture_output=True, text=True, check=True).stdout

    def gitlink(commit):
        out = git('ls-tree', commit, 'james-project').split()
        return out[2] if len(out) > 2 else None

    def modules_at(commit):
        poms = git('ls-tree', '-r', '--name-only', commit, 'tmail-backend').splitlines()
        return {os.path.dirname(f) for f in poms if f.endswith('/pom.xml')} & all_modules

    def james_changes(old, new):
        if old is None or new is None:
            return None, None
        files = git('diff', '--name-only', old, new, cwd=james).split()
        main, tests = set(), set()
        for f in files:
            if f == 'pom.xml':
                return None, None   # library versions for everything
            m = deepest_module(f, james_modules)
            if m is None or f.endswith('.md'):
                continue
            if f == m + '/pom.xml' and james_modules[m]['packaging'] == 'pom':
                main |= {james_modules[d]['artifactId'] for d in james_modules if d.startswith(m + '/')}
            elif '/src/test/' in f:
                tests.add(james_modules[m]['artifactId'])
            else:
                main.add(james_modules[m]['artifactId'])
        return main, tests

    # ---- master pushes
    log = git('log', 'master', '--first-parent', f'--since={args.since}', '--format=@@%H %ct', '--name-only')
    pushes = collections.OrderedDict()
    key = None
    for line in log.splitlines():
        if line.startswith('@@'):
            sha, key = line[2:].split()
            pushes.setdefault(key, {'commits': [], 'files': set()})['commits'].append(sha)
        elif line.strip() and key:
            pushes[key]['files'].add(line.strip())

    builds = []   # per push: (modules existing then, {strategy: modules rebuilt})
    bump_sizes = []   # per James bump not touching James's root pom: (jar modules rebuilt with the fingerprint, existing)
    kinds = collections.Counter()
    for push in pushes.values():
        files = push['files']
        present = modules_at(push['commits'][0])
        tmail_side = tmail_invalidated(files - {'james-project'})
        if 'james-project' not in files:
            kinds['no James bump'] += 1
            builds.append((present, {'revision': tmail_side, 'fingerprint': tmail_side}))
            continue
        kinds['James bump'] += 1
        main, tests = james_changes(gitlink(push['commits'][-1] + '~1'), gitlink(push['commits'][0]))
        if main is None:
            kinds['  of which James root pom'] += 1
            builds.append((present, {'revision': all_modules, 'fingerprint': all_modules}))
            continue
        using = {d for d, m in modules.items()
                 if any(a in main or (is_tests and a in tests) for a, is_tests in james_in_tree[m['artifactId']])}
        builds.append((present, {'revision': all_modules, 'fingerprint': tmail_side | with_dependents(using)}))
        bump_sizes.append((len(builds[-1][1]['fingerprint'] & present & jar_modules), len(present & jar_modules)))

    # ---- test time per module
    if args.durations:
        weights = json.load(open(args.durations))
        weight_source = args.durations
    else:
        local = collections.Counter()
        for report in glob.glob(repo + '/tmail-backend/**/target/surefire-reports/TEST-*.xml', recursive=True):
            if '/.claude/' in report:
                continue
            try:
                local[os.path.relpath(report.split('/target/')[0], repo)] += float(ET.parse(report).getroot().get('time') or 0)
            except ET.ParseError:
                pass
        classes = {d: sum(1 for _, _, fs in os.walk(os.path.join(repo, d, 'src', 'test'))
                          for f in fs if re.search(r'(Test|IT)\.(java|scala)$', f)) for d in jar_modules}
        per_class = [local[d] / classes[d] for d in local if classes.get(d) and 'integration-tests' not in d and 'deployment-tests' not in d]
        median = statistics.median(per_class) if per_class else 10.0
        weights = {d: local[d] or classes.get(d, 0) * median for d in jar_modules if local[d] or classes.get(d)}
        weight_source = f'local surefire reports, else test classes x {median:.0f}s'

    print(f'{len(builds)} master pushes since {args.since}: ' + ', '.join(f'{k} {v}' for k, v in kinds.items()))
    print(f'James bumps outside its root pom, with the fingerprint: median {statistics.median(r for r, _ in bump_sizes):.0f} '
          f'of {statistics.median(e for _, e in bump_sizes):.0f} modules (with code) rebuilt')
    print(f'test time weights: {weight_source}')
    for strategy in ('revision', 'fingerprint'):
        shares = []
        for present, rebuilt in builds:
            total = sum(w for d, w in weights.items() if d in present)
            if total:
                shares.append(sum(w for d, w in weights.items() if d in present and d not in rebuilt[strategy]) / total)
        skipped = statistics.mean(shares)
        print(f'{strategy:12s} skips {skipped * 100:4.1f}% of the Test stage: {skipped * args.test_stage_minutes:4.0f} min per master build on average')
    print('\nmodules with the most test time, rebuilt in % of the master builds where they existed (revision -> fingerprint):')
    for d, w in sorted(weights.items(), key=lambda kv: -kv[1])[:10]:
        existing = [rebuilt for present, rebuilt in builds if d in present]
        share = {strategy: sum(d in rebuilt[strategy] for rebuilt in existing) / len(existing) * 100 for strategy in ('revision', 'fingerprint')}
        print(f'  {d:75s} {share["revision"]:3.0f}% -> {share["fingerprint"]:3.0f}%')


if __name__ == '__main__':
    main()

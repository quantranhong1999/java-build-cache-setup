#!/usr/bin/env bash
# Build cache key, per module (G13): what a module gets from outside the reactor.
#
# Run from the directory the Test stage builds (TMail: tmail-backend/), with the same Maven settings and flags as that stage,
# after James was installed in the local repository (TMail: by the Compile stage). For each module, writes
# <module>/.build-cache-key/classpath.txt: every artifact of its dependency tree, transitive ones and test scope included,
# in Maven's order, with its scope, and
# - SNAPSHOT artifacts from outside the reactor (James; TMail's logback-contrib, built by the Compile stage from the root):
#   the SHA-256 of the file in the local repository. Their jars are reproducible (project.build.outputTimestamp), so an
#   unchanged module gives the same line, and a James bump only changes the keys of the modules using what changed. The hashed files must be the ones the build will use, i.e. the ones the Compile stage installed:
#   true as long as no remote repository serves newer James SNAPSHOTs (TMail's case). Otherwise, run both offline (-o);
# - released artifacts: coordinates only (a released version never changes);
# - the modules of the reactor (the current directory and below): coordinates only. The cache already chains their keys,
#   computed from their sources, including when only some of them are built (-pl, with multi-module discovery).
# The build cache configuration hashes .build-cache-key/ into each module's key.
# It only collects the dependency graph (dependency:tree): the reactor's modules need not be built or installed.
# Any failure fails the script, and so the stage: Maven failing, a James jar missing or not hashed, an unexpected tree line,
# or a module (a pom.xml below the current directory) left without fingerprint.
#
# Usage: ci/build-cache-fingerprint.sh [maven args...]
#   e.g. ci/build-cache-fingerprint.sh -B -s ../ci/maven-settings.xml -Dapi.version=1.43 -Pci-test
#        ci/build-cache-fingerprint.sh --check
#   --check, right before a cache-enabled build: fails unless every module below the current directory has its
#   fingerprint. Without it, a module's key silently ignores what it gets from James and logback-contrib (T2: a copy of the
#   sources that lost them restored stale results after a James change).
# The local repositories are the ones Maven uses with these arguments (settings, .mvn/maven.config and -D flags included).
set -euo pipefail

# The directories of the modules below the current directory
module_dirs() {
    find . -name pom.xml -not -path '*/target/*' -not -path '*/src/*' -not -path '*/.build-cache-key/*' | sed 's|/pom.xml$||' | sort
}

if [ "${1:-}" = --check ]; then
    missing=$(module_dirs | while read -r dir; do [ -f "$dir/.build-cache-key/classpath.txt" ] || echo "$dir"; done)
    if [ -n "$missing" ]; then
        echo "build cache fingerprint: no fingerprint for: $(echo "$missing" | paste -sd ' ' -) (run ci/build-cache-fingerprint.sh first)" >&2
        exit 1
    fi
    echo "build cache fingerprint: every module has its fingerprint"
    exit 0
fi

maven_value() { # expression, maven args...: prints the value, nothing when undefined
    local expression=$1 value
    shift
    value=$(mvn -q -N "$@" -Dmaven.build.cache.enabled=false org.apache.maven.plugins:maven-help-plugin:3.5.1:evaluate \
        "-Dexpression=$expression" -DforceStdout) || return 1
    if [ "$value" != "null object or invalid expression" ]; then
        echo "$value"
    fi
}

local_repository=$(maven_value settings.localRepository "$@") || exit 1
if [ ! -d "$local_repository" ]; then
    echo "build cache fingerprint: local repository not found: '$local_repository'" >&2
    exit 1
fi
repos=("$local_repository")
tail_repositories=$(maven_value maven.repo.local.tail "$@") || exit 1
if [ -n "$tail_repositories" ]; then
    IFS=',' read -r -a tail_repos <<< "$tail_repositories"
    repos+=("${tail_repos[@]}")
fi

sha256() {
    if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f 1
}

# The file of an artifact in the local repositories, empty if absent
artifact_file() { # groupId artifactId type classifier version
    local extension=$3 classifier=$4 repo path
    case $3 in
        test-jar) extension=jar; classifier=${classifier:-tests} ;;
        bundle | maven-plugin | ejb | ejb-client | java-source | javadoc) extension=jar ;;
    esac
    path="$(echo "$1" | tr '.' '/')/$2/$5/$2-$5${classifier:+-$classifier}.$extension"
    for repo in "${repos[@]}"; do
        if [ -f "$repo/$path" ]; then
            echo "$repo/$path"
            return
        fi
    done
}

find . -name .build-cache-key -type d -prune -exec rm -rf {} +
mvn -q "$@" dependency:tree -DoutputFile=.build-cache-key/tree.txt -DoutputType=text -Dverbose=false \
    -Dmaven.build.cache.enabled=false

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
find . -path '*/.build-cache-key/tree.txt' | sort > "$tmp/trees"

# Every module must have its tree: a pom.xml without one (not in the reactor, skipped...) would build without fingerprint
module_dirs | sed 's|$|/.build-cache-key/tree.txt|' > "$tmp/expected"
missing=$(comm -23 "$tmp/expected" "$tmp/trees")
if [ -n "$missing" ]; then
    echo "build cache fingerprint: no dependency tree for: $(echo "$missing" | sed 's|/.build-cache-key/tree.txt||' | paste -sd ' ' -)" >&2
    exit 1
fi

# The reactor's modules, "groupId:artifactId:version": the first line of each tree ("groupId:artifactId:packaging:version").
# The version counts: another version of a reactor module, brought by an external dependency, is an external jar
while read -r tree; do
    head -n 1 "$tree" | awk -F ':' 'NF == 4 { print $1 ":" $2 ":" $4; next } { exit 1 }'
done < "$tmp/trees" | sort -u > "$tmp/reactor"

# 1. "<.build-cache-key folder><TAB><groupId:artifactId:type[:classifier]:version><TAB><scope>" for every artifact below each
#    module, in the tree's order (the first line of a tree is the module itself)
while read -r tree; do
    tail -n +2 "$tree" | sed -E 's/^[-|+\\ ]+//; s/ .*$//' | awk -F ':' -v dir="$(dirname "$tree")" '
        NF == 5 { print dir "\t" $1 ":" $2 ":" $3 ":" $4 "\t" $5; next }
        NF == 6 { print dir "\t" $1 ":" $2 ":" $3 ":" $4 ":" $5 "\t" $6; next }
        { print "build cache fingerprint: unexpected dependency:tree line: " $0 > "/dev/stderr"; exit 1 }'
done < "$tmp/trees" > "$tmp/artifacts"

# 2. Each SNAPSHOT artifact from outside the reactor, resolved to its file and hashed once: "<coordinates><TAB><sha256>"
cut -f 2 "$tmp/artifacts" | sort -u | { grep -- '-SNAPSHOT$' || true; } | while IFS=':' read -r group artifact type fourth fifth; do
    if [ -n "$fifth" ]; then classifier=$fourth; version=$fifth; else classifier=""; version=$fourth; fi
    grep -qxF "$group:$artifact:$version" "$tmp/reactor" && continue
    coordinates="$group:$artifact:$type${classifier:+:$classifier}:$version"
    file=$(artifact_file "$group" "$artifact" "$type" "$classifier" "$version")
    if [ -z "$file" ]; then
        echo "build cache fingerprint: $coordinates not found in ${repos[*]} (run the Compile stage first)" >&2
        exit 1
    fi
    if ! hash=$(sha256 "$file") || ! echo "$hash" | grep -qE '^[0-9a-f]{64}$'; then
        echo "build cache fingerprint: cannot hash $file" >&2
        exit 1
    fi
    printf '%s\t%s\n' "$coordinates" "$hash"
done > "$tmp/hashes"

# 3. One pass: each module's lines into its classpath.txt, in the tree's order, first occurrence only
awk -F '\t' '
    FILENAME == ARGV[1] { reactor[$1] = 1; next }
    FILENAME == ARGV[2] { hash[$1] = $2; next }
    !seen[$1 FS $2]++ {
        count = split($2, all, ":"); version = all[count]
        line = $2 ":" $3
        if ((all[1] ":" all[2] ":" version) in reactor) line = line " reactor-module"
        else if (version ~ /-SNAPSHOT$/) {
            if (!($2 in hash)) { print "build cache fingerprint: no hash for " $2 > "/dev/stderr"; exit 1 }
            line = line " sha256:" hash[$2]
        }
        out = $1 "/classpath.txt"
        if (out != previous) { if (previous != "") close(previous); previous = out }
        print line >> out
    }' "$tmp/reactor" "$tmp/hashes" "$tmp/artifacts"

modules=0
while read -r tree; do
    touch "$(dirname "$tree")/classpath.txt"
    rm "$tree"
    modules=$((modules + 1))
done < "$tmp/trees"
echo "build cache fingerprint: $modules modules"

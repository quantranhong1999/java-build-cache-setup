#!/usr/bin/env bash
# Reads a Maven build log (with the build cache extension) and prints one line per jar module:
#   <artifactId> <HIT|BUILT> <tests run>
# HIT: restored from the cache and not rebuilt afterwards (a parameter mismatch, an incomplete entry, a failed restore or a cached build
# missing a requested execution forces a build). Aggregator and parent poms are left out.
set -euo pipefail

awk '
    / -+< [^ :]+:[^ ]+ >-+$/ {
        mod = $0; sub(/.*-< [^ :]+:/, "", mod); sub(/ >-.*/, "", mod)
        order[++n] = mod; tests[mod] = 0
        next
    }
    mod == "" { next }
    /-+\[ pom \]-+$/ { pom[mod] = 1 }
    /Found cached build, restoring/ { found[mod] = 1 }
    /forcing full project build|continuing with non cached build|violates cache rules|cannot restore|Failed to restore project/ { forced[mod] = 1 }
    /Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+$/ {
        line = $0; sub(".*Tests run: ", "", line); split(line, parts, ","); tests[mod] += parts[1]
    }
    END {
        for (i = 1; i <= n; i++) {
            m = order[i]
            if (m in pom) continue
            print m, ((m in found) && !(m in forced)) ? "HIT" : "BUILT", tests[m]
        }
    }' "$1"

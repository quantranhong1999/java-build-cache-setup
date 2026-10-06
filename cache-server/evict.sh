#!/bin/sh
# Cleanup of the build cache, every few minutes, entry by entry
# (an entry is a folder <project>/v1.2/<groupId>/<artifactId>/<key>/):
# - verification: each new entry with a buildinfo.xml has its files checked against the SHA-256 hashes listed there.
#   A missing file or a different hash (an upload interrupted, then completed by another build of the same key) deletes
#   the whole entry: the next master build saves a consistent one. Verified entries are marked with .verified (nginx only
#   serves those, and refuses uploads of dot-files); an entry holding a file newer than its marker is verified again;
# - expiry: an entry whose newest file is older than CACHE_RETENTION_DAYS (default 21) is deleted as a whole. Entries are
#   immutable, so this is safe: an entry still in use is rebuilt once and saved again;
# - incomplete uploads: an entry without buildinfo.xml (nor build-cache-report.xml) older than a day is deleted.
# Then empty folders are removed. The upload temp folder is excluded with '! -path' rather than '-prune':
# with GNU find, -delete disables -prune.
set -eu

DATA_DIR="${CACHE_DATA_DIR:-/data}"
RETENTION_DAYS="${CACHE_RETENTION_DAYS:-21}"
UPLOAD_TMP="$DATA_DIR/.upload-tmp"

# Prints "<fileName> <fileHash>" for each file listed in a buildinfo.xml
listed_files() {
    awk '
        /<fileName>/ { name = $0; sub(/.*<fileName>/, "", name); sub(/<\/fileName>.*/, "", name) }
        /<fileHash>/ { hash = $0; sub(/.*<fileHash>/, "", hash); sub(/<\/fileHash>.*/, "", hash); print name, hash }
    ' "$1"
}

is_consistent() { # entry folder
    listed_files "$1/buildinfo.xml" | while read -r name hash; do
        if [ ! -f "$1/$name" ] || [ "$(sha256sum "$1/$name" | cut -d ' ' -f 1)" != "$hash" ]; then
            echo "$name"
            return
        fi
    done
}

find "$DATA_DIR" -mindepth 5 -maxdepth 5 -type d ! -path "$UPLOAD_TMP/*" | while read -r entry; do
    if [ -z "$(find "$entry" -type f ! -name .verified -mtime "-$RETENTION_DAYS" | head -n 1)" ]; then
        echo "expired: $entry"
        rm -rf "$entry"
    elif [ -f "$entry/buildinfo.xml" ]; then
        if [ ! -f "$entry/.verified" ] || [ -n "$(find "$entry" -type f ! -name .verified -newer "$entry/.verified" | head -n 1)" ]; then
            bad=$(is_consistent "$entry")
            if [ -n "$bad" ]; then
                echo "inconsistent ($bad): $entry"
                rm -rf "$entry"
            else
                touch "$entry/.verified"
            fi
        fi
    elif [ ! -f "$entry/build-cache-report.xml" ] && [ -z "$(find "$entry" -type f -mtime -1 | head -n 1)" ]; then
        echo "incomplete upload: $entry"
        rm -rf "$entry"
    fi
done

find "$DATA_DIR" -mindepth 1 -type d -empty ! -path "$UPLOAD_TMP" ! -path "$UPLOAD_TMP/*" -print -delete

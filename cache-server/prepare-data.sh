#!/bin/sh
# Run by the nginx image entrypoint (/docker-entrypoint.d) as root, before nginx starts:
# the upload temp folder must live on the same volume as the entries, writable by the nginx workers.
set -eu
mkdir -p /data/.upload-tmp
chown -R nginx:nginx /data

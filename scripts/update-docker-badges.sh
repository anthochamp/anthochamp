#!/bin/sh
# Usage: update-docker-badges.sh README.md
# Rewrites each static `docker-<version>` badge with the highest x.y.z tag of
# the Docker Hub repository linked on the same line. Shields.io cannot read
# these repositories itself: their tag lists are mostly cosign signatures.
set -eu
readme=$1
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

while IFS= read -r line
do
  repository=$(printf '%s\n' "$line" | sed -n 's#.*https://hub\.docker\.com/r/\([^/)]*/[^/)]*\)).*img\.shields\.io/badge/docker-.*#\1#p')
  if [ -n "$repository" ]
  then
    version=$(curl -sf --retry 3 "https://hub.docker.com/v2/namespaces/${repository%%/*}/repositories/${repository#*/}/tags?page_size=100" |
      jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
    if [ -n "$version" ]
    then
      line=$(printf '%s\n' "$line" | sed "s#img\.shields\.io/badge/docker-[^-]*-blue#img.shields.io/badge/docker-v$version-blue#")
    fi
  fi
  printf '%s\n' "$line"
done < "$readme" > "$tmp"
cat "$tmp" > "$readme"

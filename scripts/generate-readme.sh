#!/bin/sh
# Usage: generate-readme.sh > README.md
# Lists the public repositories of OWNER on the forge, the state of their last
# finished pipeline on the default branch, and the latest version of what
# they publish on Docker Hub, npm and pub.dev.
set -eu

server=${FORGEJO_SERVER_URL:-https://git.grenadine.io}
api=${FORGEJO_API_URL:-$server/api/v1}
owner=${OWNER:-anthochamp}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

get() {
  curl -sf --retry 3 "$1"
}

# Highest x.y.z tag of a Docker Hub repository, empty when there is none.
dockerhub_version() {
  get "https://hub.docker.com/v2/namespaces/$1/repositories/$2/tags?page_size=100" 2>/dev/null |
    jq -r '.results[].name' | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true
}

npm_version() {
  get "https://registry.npmjs.org/$1/latest" 2>/dev/null | jq -r '.version // empty' || true
}

pub_version() {
  get "https://pub.dev/api/packages/$1" 2>/dev/null | jq -r '.latest.version // empty' || true
}

# State of the last finished run on the default branch, as a Markdown link.
pipeline() {
  repo=$1
  branch=$2
  get "$api/repos/$owner/$repo/actions/runs?ref=refs/heads/$branch&limit=20" 2>/dev/null |
    jq -r '[.workflow_runs[]? | select(.status == "success" or .status == "failure")][0]
      // empty | "[\(if .status == "success" then "passing" else .status end)](\(.html_url))"' || true
}

page=1
while :
do
  batch=$(get "$api/users/$owner/repos?limit=50&page=$page")
  if [ "$(echo "$batch" | jq 'length')" -eq 0 ]
  then
    break
  fi
  echo "$batch" | jq -c --arg owner "$owner" '.[]
    | select(.private == false and .fork == false and .archived == false and .empty == false
             and .mirror == false and .name != $owner)
    | {name, description, branch: .default_branch, url: .html_url, actions: .has_actions}' >> "$work/repos"
  page=$((page + 1))
done
sort -o "$work/repos" "$work/repos"

: > "$work/containers"
: > "$work/dart"
: > "$work/npm"
: > "$work/other"

while IFS= read -r repo
do
  name=$(echo "$repo" | jq -r '.name')
  url=$(echo "$repo" | jq -r '.url')
  branch=$(echo "$repo" | jq -r '.branch')
  description=$(echo "$repo" | jq -r '.description // "" | gsub("\\|"; "\\|")')
  status=-
  if [ "$(echo "$repo" | jq -r '.actions')" = true ]
  then
    status=$(pipeline "$name" "$branch")
    status=${status:--}
  fi
  source="[$name]($url)"
  tree=$(get "$api/repos/$owner/$name/git/trees/$branch?recursive=true&per_page=10000" | jq -r '.tree[].path')

  case $name in
    container-*)
      image=${name#container-}
      version=$(dockerhub_version "$owner" "$image")
      printf '| %s | %s | [%s/%s](https://hub.docker.com/r/%s/%s) | %s | %s |\n' \
        "$source" "$status" "$owner" "$image" "$owner" "$image" "${version:--}" "$description" >> "$work/containers"
      continue
      ;;
    docker-plugin-*)
      plugin=${name#docker-plugin-}-amd64
      version=$(dockerhub_version "$owner" "$plugin")
      printf '| %s | %s | [%s/%s](https://hub.docker.com/r/%s/%s) | %s | %s |\n' \
        "$source" "$status" "$owner" "$plugin" "$owner" "$plugin" "${version:--}" "$description" >> "$work/containers"
      continue
      ;;
  esac

  if echo "$tree" | grep -qx 'pubspec.yaml'
  then
    package=$(get "$api/repos/$owner/$name/raw/pubspec.yaml?ref=$branch" | sed -n 's/^name: *//p' | head -n 1)
    version=$(pub_version "$package")
    if [ -n "$version" ]
    then
      published="[$package](https://pub.dev/packages/$package) | $version"
    else
      published="$package | not published"
    fi
    printf '| %s | %s | %s | %s |\n' "$source" "$status" "$published" "$description" >> "$work/dart"
    continue
  fi

  manifests=$(echo "$tree" | grep -E '^([^/]+/[^/]+/)?package\.json$' | grep -v node_modules || true)
  published_npm=0
  for manifest in $manifests
  do
    get "$api/repos/$owner/$name/raw/$manifest?ref=$branch" > "$work/manifest"
    if [ "$(jq -r '.private // false' "$work/manifest")" = true ]
    then
      continue
    fi
    package=$(jq -r '.name' "$work/manifest")
    version=$(npm_version "$package")
    if [ -n "$version" ]
    then
      printf '| [%s](https://www.npmjs.com/package/%s) | %s | %s | %s |\n' \
        "$package" "$package" "$version" "$source" "$status" >> "$work/npm"
      published_npm=1
    fi
  done
  if [ "$published_npm" -eq 1 ]
  then
    continue
  fi

  printf '| %s | %s | %s |\n' "$source" "$status" "$description" >> "$work/other"
done < "$work/repos"

cat <<EOF
# Anthony Champagne

My public code lives on [git.grenadine.io]($server/$owner): sources, issues
and releases are there. This page is generated from it and mirrored to GitHub;
the GitHub account holds no other repository of mine.

"Pipeline" is the last finished CI run on the default branch.
EOF

section() {
  if [ -s "$2" ]
  then
    printf '\n## %s\n\n%s\n%s\n' "$1" "$3" "$4"
    sort "$2"
  fi
}

section "Container images" "$work/containers" \
  '| Source | Pipeline | Docker Hub | Latest | Description |' \
  '| ------ | -------- | ---------- | ------ | ----------- |'
section "Dart and Flutter packages" "$work/dart" \
  '| Source | Pipeline | pub.dev | Latest | Description |' \
  '| ------ | -------- | ------- | ------ | ----------- |'
section "npm packages" "$work/npm" \
  '| Package | Latest | Source | Pipeline |' \
  '| ------- | ------ | ------ | -------- |'
section "Other repositories" "$work/other" \
  '| Source | Pipeline | Description |' \
  '| ------ | -------- | ----------- |'

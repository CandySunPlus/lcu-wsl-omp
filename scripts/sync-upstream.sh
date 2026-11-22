#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [vMAJOR.MINOR.PATCH]\n' "$0"
  printf 'Prepare a local sync branch from origin/main. Defaults to the latest upstream GitHub release (requires gh).\n'
}
if (( $# > 1 )); then
  usage >&2
  exit 2
fi
if [[ ${1-} == --help || ${1-} == -h ]]; then
  usage
  exit 0
fi

upstream=amontlabs/lcu
tag=${1-}
if [[ -z "$tag" ]]; then
  if ! command -v gh >/dev/null; then
    printf 'Install GitHub CLI or pass the upstream release tag explicitly.\n' >&2
    exit 1
  fi
  tag=$(gh release view --repo "$upstream" --json tagName --jq .tagName)
fi
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Expected a stable upstream release tag (vMAJOR.MINOR.PATCH), got: %s\n' "$tag" >&2
  exit 2
fi

cd -- "$(git rev-parse --show-toplevel)"
if [[ -n "$(git status --porcelain=v1)" ]]; then
  printf 'The worktree is not clean. Save your changes before syncing.\n' >&2
  exit 1
fi

git fetch --no-tags origin refs/heads/main
base=$(git rev-parse --verify 'FETCH_HEAD^{commit}')
git fetch --no-tags "https://github.com/$upstream.git" "refs/tags/$tag"
release=$(git rev-parse --verify 'FETCH_HEAD^{commit}')
if git merge-base --is-ancestor "$release" "$base"; then
  printf 'origin/main already contains upstream %s. Nothing to sync.\n' "$tag"
  exit 0
fi
if ! command -v node >/dev/null; then
  printf 'Node is required to run the Windows compatibility tests.\n' >&2
  exit 1
fi

branch="sync-upstream/$tag"
git switch -c "$branch" "$base"
if ! git merge --no-ff --no-edit "$release"; then
  printf 'Merge stopped on %s. Inspect git status, then resolve and run git merge --continue, or run git merge --abort.\n' "$branch" >&2
  exit 1
fi
if ! node --test tests/node/install_windows.test.mjs tests/node/windows.test.mjs \
  tests/node/windows_host.test.mjs tests/node/maintenance.test.mjs; then
  printf 'Compatibility tests failed on %s. Nothing was pushed or installed.\n' "$branch" >&2
  exit 1
fi
printf '\nPrepared %s; local compatibility tests passed. Nothing was pushed or installed.\n' "$branch"
printf 'Verify in-place operation on Windows and WSL omp before publishing this branch.\n'

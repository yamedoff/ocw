#!/usr/bin/env bash
# setup-worktrees.sh - create one git worktree per branch inside a Codespace.
#
# ocw runs one worker per worktree, so a lane needs an isolated checkout before
# it can start. This creates those checkouts idempotently: an existing worktree
# is reused, and a missing local branch is created from origin.
#
# Usage:
#   setup-worktrees.sh REPOSITORY WORKTREE_ROOT BRANCH[=DIRECTORY]...
#   setup-worktrees.sh REPOSITORY WORKTREE_ROOT --link NAME=PATH BRANCH...
#
# --link symlinks a shared directory into every worktree, which is how a repo
# keeps one orchestration folder (prompts, run logs) visible from each lane
# without committing it. The name is added to the repository's local git
# exclude file so it never shows up as an untracked change.

set -Eeuo pipefail

# The Codespaces-managed token exists on disk but is not exported by an SSH
# command session. Export it only within this process for authenticated Git.
if [[ -r /workspaces/.codespaces/shared/.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /workspaces/.codespaces/shared/.env
  set +a
fi

links=()
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --link)
      [[ $# -ge 2 ]] || { printf 'setup-worktrees: --link needs NAME=PATH\n' >&2; exit 2; }
      links+=("$2")
      shift 2
      ;;
    --link=*)
      links+=("${1#--link=}")
      shift
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

if [[ ${#positional[@]} -lt 3 ]]; then
  printf 'Usage: setup-worktrees.sh REPOSITORY WORKTREE_ROOT BRANCH[=DIRECTORY]... [--link NAME=PATH]\n' >&2
  exit 2
fi

repository="${positional[0]}"
worktree_root="${positional[1]}"
branches=("${positional[@]:2}")

[[ -d "$repository/.git" ]] || { printf 'Repository not found: %s\n' "$repository" >&2; exit 2; }
mkdir -p "$worktree_root"
git -C "$repository" fetch --prune origin

# Local excludes keep shared, uncommitted folders out of `git status` in every
# worktree without touching the repository's tracked .gitignore.
if [[ ${#links[@]} -gt 0 ]]; then
  git_directory="$(git -C "$repository" rev-parse --absolute-git-dir)"
  exclude_file="$git_directory/info/exclude"
  for link in "${links[@]}"; do
    name="${link%%=*}"
    if ! grep -Fxq "$name" "$exclude_file" 2>/dev/null; then
      printf '\n%s\n' "$name" >> "$exclude_file"
    fi
  done
fi

for specification in "${branches[@]}"; do
  branch="${specification%%=*}"
  if [[ "$specification" == *"="* ]]; then
    directory="${specification#*=}"
  else
    # A branch like feature/login is not a valid single directory name.
    directory="${branch//\//-}"
  fi
  destination="$worktree_root/$directory"

  if [[ ! -e "$destination/.git" ]]; then
    if git -C "$repository" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$repository" worktree add "$destination" "$branch"
    else
      git -C "$repository" worktree add --track -b "$branch" "$destination" "origin/$branch"
    fi
  fi

  for link in "${links[@]}"; do
    name="${link%%=*}"
    target="${link#*=}"
    if [[ ! -e "$destination/$name" ]]; then
      ln -s "$target" "$destination/$name"
    fi
  done

  printf '%s %s\n' "$branch" "$destination"
done

#!/usr/bin/env bash
# diagnose.sh — Collect git repository state for the git-sprint-start skill.
#
# Output: a single JSON object to stdout with these fields:
#   repo_root           string   Absolute path to repo root
#   default_branch      string   Detected default branch name (e.g. "main")
#   current_branch      string   Current branch (or "HEAD detached" if detached)
#   remote_name         string   Expected "origin"; empty if missing
#   all_remotes         array    List of all configured remote names
#   is_clean            bool     True if working tree + index are clean
#   staged_files        array    Files in the index (staged for commit)
#   modified_files      array    Modified but unstaged files
#   untracked_files     array    Untracked files
#   deleted_files       array    Deleted files
#   has_conflicts       bool     True if unmerged paths exist
#   conflict_files      array    Files with merge conflicts
#   commits_ahead       int      Commits ahead of origin/default_branch
#   commits_behind      int      Commits behind origin/default_branch
#   merge_in_progress   bool     True if .git/MERGE_HEAD exists
#   rebase_in_progress  bool     True if rebase dir exists
#   head_detached       bool     True if HEAD is detached
#   has_contributing     bool     True if CONTRIBUTING.md found
#   contributing_path   string   Path to CONTRIBUTING.md (empty if not found)
#   last_fetch_ts       string   ISO-8601 timestamp of last fetch (empty if never)
#   errors              array    Non-fatal warnings/errors encountered
#
# Exit codes:
#   0  success (JSON on stdout)
#   1  not inside a git repository
#   2  unexpected fatal error

set -euo pipefail

# --- helpers -----------------------------------------------------------------
json_array() {
    # Turn newline-separated input into a JSON array of strings
    local input="$1"
    if [[ -z "$input" ]]; then
        echo "[]"
        return
    fi
    echo "$input" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().strip().split('\n') if l]
print(json.dumps(lines))
"
}

json_string() {
    python3 -c "import json; print(json.dumps('$1'))"
}

# --- pre-checks --------------------------------------------------------------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo '{"error": "Not a git repository"}' >&2
    exit 1
}
cd "$REPO_ROOT"

ERRORS=()

# --- remote ------------------------------------------------------------------
ALL_REMOTES=$(git remote 2>/dev/null || true)
REMOTE_NAME=""
if echo "$ALL_REMOTES" | grep -qx "origin"; then
    REMOTE_NAME="origin"
else
    if [[ -n "$ALL_REMOTES" ]]; then
        ERRORS+=("Remote 'origin' not found. Detected remotes: $(echo "$ALL_REMOTES" | tr '\n' ', ' | sed 's/, $//')")
    else
        ERRORS+=("No remotes configured in this repository")
    fi
fi

# --- default branch detection ------------------------------------------------
DEFAULT_BRANCH=""

if [[ -n "$REMOTE_NAME" ]]; then
    # Method 1: symbolic-ref
    DEFAULT_BRANCH=$(git symbolic-ref "refs/remotes/${REMOTE_NAME}/HEAD" 2>/dev/null \
        | sed "s|refs/remotes/${REMOTE_NAME}/||" || true)

    # Method 2: check for common names
    if [[ -z "$DEFAULT_BRANCH" ]]; then
        for candidate in main master; do
            if git show-ref --verify --quiet "refs/remotes/${REMOTE_NAME}/${candidate}" 2>/dev/null; then
                DEFAULT_BRANCH="$candidate"
                break
            fi
        done
    fi

    # Method 3: first remote branch
    if [[ -z "$DEFAULT_BRANCH" ]]; then
        DEFAULT_BRANCH=$(git branch -r --list "${REMOTE_NAME}/*" 2>/dev/null \
            | head -1 | sed "s|.*${REMOTE_NAME}/||" | xargs || true)
        if [[ -n "$DEFAULT_BRANCH" ]]; then
            ERRORS+=("Could not detect default branch reliably; using first remote branch: ${DEFAULT_BRANCH}")
        fi
    fi
fi

if [[ -z "$DEFAULT_BRANCH" ]]; then
    # Last resort: local branches
    for candidate in main master; do
        if git show-ref --verify --quiet "refs/heads/${candidate}" 2>/dev/null; then
            DEFAULT_BRANCH="$candidate"
            ERRORS+=("Detected default branch from local refs only: ${DEFAULT_BRANCH}")
            break
        fi
    done
fi

[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="unknown" && ERRORS+=("Unable to detect default branch")

# --- current branch -----------------------------------------------------------
HEAD_DETACHED=false
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)
if [[ -z "$CURRENT_BRANCH" ]]; then
    CURRENT_BRANCH="HEAD detached"
    HEAD_DETACHED=true
fi

# --- working tree status ------------------------------------------------------
STAGED=$(git diff --cached --name-only 2>/dev/null || true)
MODIFIED=$(git diff --name-only 2>/dev/null || true)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)
DELETED=$(git diff --name-only --diff-filter=D 2>/dev/null || true)

# conflicts (unmerged)
CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
HAS_CONFLICTS=false
[[ -n "$CONFLICT_FILES" ]] && HAS_CONFLICTS=true

IS_CLEAN=false
if [[ -z "$STAGED" && -z "$MODIFIED" && -z "$UNTRACKED" && -z "$CONFLICT_FILES" ]]; then
    IS_CLEAN=true
fi

# --- sync status with remote --------------------------------------------------
AHEAD=0
BEHIND=0
if [[ -n "$REMOTE_NAME" && "$DEFAULT_BRANCH" != "unknown" ]]; then
    UPSTREAM="refs/remotes/${REMOTE_NAME}/${DEFAULT_BRANCH}"
    if git show-ref --verify --quiet "$UPSTREAM" 2>/dev/null; then
        COUNTS=$(git rev-list --left-right --count "HEAD...$UPSTREAM" 2>/dev/null || echo "0	0")
        AHEAD=$(echo "$COUNTS" | awk '{print $1}')
        BEHIND=$(echo "$COUNTS" | awk '{print $2}')
    else
        ERRORS+=("Upstream ref $UPSTREAM not found locally; run 'git fetch' first")
    fi
fi

# --- in-progress operations ---------------------------------------------------
MERGE_IN_PROGRESS=false
[[ -f "$REPO_ROOT/.git/MERGE_HEAD" ]] && MERGE_IN_PROGRESS=true

REBASE_IN_PROGRESS=false
[[ -d "$REPO_ROOT/.git/rebase-merge" || -d "$REPO_ROOT/.git/rebase-apply" ]] && REBASE_IN_PROGRESS=true

# --- CONTRIBUTING.md ----------------------------------------------------------
HAS_CONTRIBUTING=false
CONTRIBUTING_PATH=""
# Case-insensitive search at repo root only
FOUND=$(find "$REPO_ROOT" -maxdepth 1 -iname "contributing.md" -print -quit 2>/dev/null || true)
if [[ -n "$FOUND" ]]; then
    HAS_CONTRIBUTING=true
    CONTRIBUTING_PATH="$FOUND"
fi

# --- last fetch timestamp -----------------------------------------------------
LAST_FETCH_TS=""
FETCH_HEAD="$REPO_ROOT/.git/FETCH_HEAD"
if [[ -f "$FETCH_HEAD" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        LAST_FETCH_TS=$(stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%S" "$FETCH_HEAD" 2>/dev/null || true)
    else
        LAST_FETCH_TS=$(stat -c "%y" "$FETCH_HEAD" 2>/dev/null | cut -d'.' -f1 || true)
    fi
fi

# --- build JSON output --------------------------------------------------------
ERRORS_JSON=$(printf '%s\n' "${ERRORS[@]+"${ERRORS[@]}"}" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().strip().split('\n') if l]
print(json.dumps(lines))
")

cat <<ENDJSON
{
  "repo_root": $(json_string "$REPO_ROOT"),
  "default_branch": $(json_string "$DEFAULT_BRANCH"),
  "current_branch": $(json_string "$CURRENT_BRANCH"),
  "remote_name": $(json_string "$REMOTE_NAME"),
  "all_remotes": $(json_array "$ALL_REMOTES"),
  "is_clean": $IS_CLEAN,
  "staged_files": $(json_array "$STAGED"),
  "modified_files": $(json_array "$MODIFIED"),
  "untracked_files": $(json_array "$UNTRACKED"),
  "deleted_files": $(json_array "$DELETED"),
  "has_conflicts": $HAS_CONFLICTS,
  "conflict_files": $(json_array "$CONFLICT_FILES"),
  "commits_ahead": $AHEAD,
  "commits_behind": $BEHIND,
  "merge_in_progress": $MERGE_IN_PROGRESS,
  "rebase_in_progress": $REBASE_IN_PROGRESS,
  "head_detached": $HEAD_DETACHED,
  "has_contributing": $HAS_CONTRIBUTING,
  "contributing_path": $(json_string "$CONTRIBUTING_PATH"),
  "last_fetch_ts": $(json_string "$LAST_FETCH_TS"),
  "errors": $ERRORS_JSON
}
ENDJSON

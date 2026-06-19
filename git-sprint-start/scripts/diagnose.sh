#!/usr/bin/env bash
# diagnose.sh — Collect git repository state for the git-sprint-start skill.
#
# WORKFLOW: fetch first (with --prune), then diagnose. All comparisons use
# the REMOTE default branch (origin/<default>) as source of truth.
#
# Output: a single JSON object to stdout. Fields grouped by concern:
#
#   --- context ---
#   repo_root               string   Absolute path to repo root
#   default_branch          string   Detected default branch name
#   current_branch          string   Current branch (or "HEAD detached")
#   remote_name             string   Expected "origin"; empty if missing
#   all_remotes             array    All configured remote names
#   head_detached           bool     HEAD is detached
#   has_contributing        bool     CONTRIBUTING.md found at repo root
#   contributing_path       string   Path to CONTRIBUTING.md
#
#   --- fetch ---
#   fetch_ok                bool     git fetch succeeded
#   fetch_error             string   Error message if fetch failed
#   last_fetch_ts           string   Timestamp of fetch
#
#   --- local default vs remote default ---
#   local_default_exists    bool     Local default branch exists
#   local_default_ahead     int      Commits in local default NOT in origin/default
#   local_default_behind    int      Commits in origin/default NOT in local default
#   local_default_synced    bool     ahead=0 AND behind=0
#   local_default_commit    string   Short SHA of local default tip
#   remote_default_commit   string   Short SHA of origin/default tip
#
#   --- current HEAD vs remote default ---
#   head_ahead              int      Commits in HEAD NOT in origin/default
#   head_behind             int      Commits in origin/default NOT in HEAD
#
#   --- workflow flags ---
#   working_on_default      bool     current_branch == default_branch (violation)
#   branch_merged           bool     Current branch is fully merged in origin/default
#   remote_branch_exists    bool     Current branch exists on remote (false = deleted)
#
#   --- stash ---
#   stash_count             int      Number of stash entries
#   stash_entries           array    List of stash descriptions (most recent first)
#
#   --- working tree ---
#   is_clean                bool     Working tree + index are clean
#   staged_files            array    Staged files
#   modified_files          array    Modified unstaged files
#   untracked_files         array    Untracked files
#   deleted_files           array    Deleted files
#   has_conflicts           bool     Unmerged paths exist
#   conflict_files          array    Files with merge conflicts
#   merge_in_progress       bool     .git/MERGE_HEAD exists
#   rebase_in_progress      bool     rebase dir exists
#
#   --- diagnostics ---
#   errors                  array    Non-fatal warnings
#
# Exit codes:  0 = success,  1 = not a git repo,  2 = fatal error

set -euo pipefail

# --- helpers -----------------------------------------------------------------
json_array() {
    local input="$1"
    if [[ -z "$input" ]]; then echo "[]"; return; fi
    echo "$input" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().strip().split('\n') if l]
print(json.dumps(lines))
"
}

json_string() {
    printf '%s' "$1" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))"
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

# --- STEP 1: FETCH with --prune ----------------------------------------------
# --prune removes remote-tracking refs for branches deleted on the remote
# (e.g. after a PR merge + branch delete on GitHub).
FETCH_OK=false
FETCH_ERROR=""
if [[ -n "$REMOTE_NAME" ]]; then
    if FETCH_OUTPUT=$(git fetch --prune "$REMOTE_NAME" 2>&1); then
        FETCH_OK=true
    else
        FETCH_ERROR="$FETCH_OUTPUT"
        ERRORS+=("git fetch failed: $FETCH_ERROR")
    fi
else
    FETCH_ERROR="No remote 'origin' to fetch from"
fi

# --- default branch detection (uses FRESH remote refs after fetch) -----------
DEFAULT_BRANCH=""

if [[ -n "$REMOTE_NAME" ]]; then
    DEFAULT_BRANCH=$(git symbolic-ref "refs/remotes/${REMOTE_NAME}/HEAD" 2>/dev/null \
        | sed "s|refs/remotes/${REMOTE_NAME}/||" || true)

    if [[ -z "$DEFAULT_BRANCH" ]]; then
        for candidate in main master; do
            if git show-ref --verify --quiet "refs/remotes/${REMOTE_NAME}/${candidate}" 2>/dev/null; then
                DEFAULT_BRANCH="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$DEFAULT_BRANCH" ]]; then
        DEFAULT_BRANCH=$(git branch -r --list "${REMOTE_NAME}/*" 2>/dev/null \
            | grep -v HEAD | head -1 | sed "s|.*${REMOTE_NAME}/||" | xargs || true)
        if [[ -n "$DEFAULT_BRANCH" ]]; then
            ERRORS+=("Could not detect default branch reliably; using first remote branch: ${DEFAULT_BRANCH}")
        fi
    fi
fi

if [[ -z "$DEFAULT_BRANCH" ]]; then
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

# --- STEP 2: LOCAL DEFAULT vs REMOTE DEFAULT ----------------------------------
LOCAL_DEFAULT_EXISTS=false
LOCAL_DEFAULT_AHEAD=0
LOCAL_DEFAULT_BEHIND=0
LOCAL_DEFAULT_SYNCED=false
LOCAL_DEFAULT_COMMIT=""
REMOTE_DEFAULT_COMMIT=""

REMOTE_REF="refs/remotes/${REMOTE_NAME}/${DEFAULT_BRANCH}"
LOCAL_REF="refs/heads/${DEFAULT_BRANCH}"

if [[ -n "$REMOTE_NAME" && "$DEFAULT_BRANCH" != "unknown" ]]; then
    if git show-ref --verify --quiet "$REMOTE_REF" 2>/dev/null; then
        REMOTE_DEFAULT_COMMIT=$(git rev-parse --short "$REMOTE_REF" 2>/dev/null || true)
    fi

    if git show-ref --verify --quiet "$LOCAL_REF" 2>/dev/null; then
        LOCAL_DEFAULT_EXISTS=true
        LOCAL_DEFAULT_COMMIT=$(git rev-parse --short "$LOCAL_REF" 2>/dev/null || true)

        if [[ -n "$REMOTE_DEFAULT_COMMIT" ]]; then
            COUNTS=$(git rev-list --left-right --count "${LOCAL_REF}...${REMOTE_REF}" 2>/dev/null || echo "0	0")
            LOCAL_DEFAULT_AHEAD=$(echo "$COUNTS" | awk '{print $1}')
            LOCAL_DEFAULT_BEHIND=$(echo "$COUNTS" | awk '{print $2}')
            if [[ "$LOCAL_DEFAULT_AHEAD" -eq 0 && "$LOCAL_DEFAULT_BEHIND" -eq 0 ]]; then
                LOCAL_DEFAULT_SYNCED=true
            fi
        fi
    else
        ERRORS+=("Local branch '${DEFAULT_BRANCH}' does not exist; only remote tracking ref found")
    fi
fi

# --- STEP 3: CURRENT HEAD vs REMOTE DEFAULT -----------------------------------
HEAD_AHEAD=0
HEAD_BEHIND=0
if [[ -n "$REMOTE_NAME" && "$DEFAULT_BRANCH" != "unknown" ]]; then
    if git show-ref --verify --quiet "$REMOTE_REF" 2>/dev/null; then
        COUNTS=$(git rev-list --left-right --count "HEAD...${REMOTE_REF}" 2>/dev/null || echo "0	0")
        HEAD_AHEAD=$(echo "$COUNTS" | awk '{print $1}')
        HEAD_BEHIND=$(echo "$COUNTS" | awk '{print $2}')
    fi
fi

# --- STEP 4: WORKFLOW FLAGS ---------------------------------------------------

# Flag: working directly on default branch
WORKING_ON_DEFAULT=false
if [[ "$HEAD_DETACHED" == "false" && "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
    WORKING_ON_DEFAULT=true
fi

# Flag: current branch already merged in remote default
BRANCH_MERGED=false
if [[ "$HEAD_DETACHED" == "false" && "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]]; then
    if git show-ref --verify --quiet "$REMOTE_REF" 2>/dev/null; then
        # If all commits in current branch are reachable from origin/default,
        # the branch is fully merged. head_ahead==0 is necessary but not
        # sufficient (could be same commit). Check merge-base explicitly.
        MERGE_BASE=$(git merge-base HEAD "$REMOTE_REF" 2>/dev/null || true)
        HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)
        if [[ -n "$MERGE_BASE" && "$MERGE_BASE" == "$HEAD_SHA" ]]; then
            BRANCH_MERGED=true
        fi
    fi
fi

# Flag: current branch still exists on remote
REMOTE_BRANCH_EXISTS=false
if [[ "$HEAD_DETACHED" == "false" && "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]]; then
    if git show-ref --verify --quiet "refs/remotes/${REMOTE_NAME}/${CURRENT_BRANCH}" 2>/dev/null; then
        REMOTE_BRANCH_EXISTS=true
    fi
fi

# --- STEP 5: STASH -----------------------------------------------------------
STASH_COUNT=0
STASH_LIST=""
if STASH_RAW=$(git stash list 2>/dev/null); then
    if [[ -n "$STASH_RAW" ]]; then
        STASH_COUNT=$(echo "$STASH_RAW" | wc -l | tr -d ' ')
        STASH_LIST="$STASH_RAW"
    fi
fi

# --- working tree status ------------------------------------------------------
STAGED=$(git diff --cached --name-only 2>/dev/null || true)
MODIFIED=$(git diff --name-only 2>/dev/null || true)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)
DELETED=$(git diff --name-only --diff-filter=D 2>/dev/null || true)

CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
HAS_CONFLICTS=false
[[ -n "$CONFLICT_FILES" ]] && HAS_CONFLICTS=true

IS_CLEAN=false
if [[ -z "$STAGED" && -z "$MODIFIED" && -z "$UNTRACKED" && -z "$CONFLICT_FILES" ]]; then
    IS_CLEAN=true
fi

# --- in-progress operations ---------------------------------------------------
MERGE_IN_PROGRESS=false
[[ -f "$REPO_ROOT/.git/MERGE_HEAD" ]] && MERGE_IN_PROGRESS=true

REBASE_IN_PROGRESS=false
[[ -d "$REPO_ROOT/.git/rebase-merge" || -d "$REPO_ROOT/.git/rebase-apply" ]] && REBASE_IN_PROGRESS=true

# --- CONTRIBUTING.md ----------------------------------------------------------
HAS_CONTRIBUTING=false
CONTRIBUTING_PATH=""
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
  "head_detached": $HEAD_DETACHED,
  "has_contributing": $HAS_CONTRIBUTING,
  "contributing_path": $(json_string "$CONTRIBUTING_PATH"),

  "fetch_ok": $FETCH_OK,
  "fetch_error": $(json_string "$FETCH_ERROR"),
  "last_fetch_ts": $(json_string "$LAST_FETCH_TS"),

  "local_default_exists": $LOCAL_DEFAULT_EXISTS,
  "local_default_ahead": $LOCAL_DEFAULT_AHEAD,
  "local_default_behind": $LOCAL_DEFAULT_BEHIND,
  "local_default_synced": $LOCAL_DEFAULT_SYNCED,
  "local_default_commit": $(json_string "$LOCAL_DEFAULT_COMMIT"),
  "remote_default_commit": $(json_string "$REMOTE_DEFAULT_COMMIT"),

  "head_ahead": $HEAD_AHEAD,
  "head_behind": $HEAD_BEHIND,

  "working_on_default": $WORKING_ON_DEFAULT,
  "branch_merged": $BRANCH_MERGED,
  "remote_branch_exists": $REMOTE_BRANCH_EXISTS,

  "stash_count": $STASH_COUNT,
  "stash_entries": $(json_array "$STASH_LIST"),

  "is_clean": $IS_CLEAN,
  "staged_files": $(json_array "$STAGED"),
  "modified_files": $(json_array "$MODIFIED"),
  "untracked_files": $(json_array "$UNTRACKED"),
  "deleted_files": $(json_array "$DELETED"),
  "has_conflicts": $HAS_CONFLICTS,
  "conflict_files": $(json_array "$CONFLICT_FILES"),
  "merge_in_progress": $MERGE_IN_PROGRESS,
  "rebase_in_progress": $REBASE_IN_PROGRESS,

  "errors": $ERRORS_JSON
}
ENDJSON

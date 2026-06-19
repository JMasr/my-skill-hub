---
name: git-sprint-start
description: >
  Pre-flight check and branch setup for starting a new work session or sprint
  in a git repository. Use this skill whenever the user says things like
  "start a new sprint", "new branch", "prepare repo for work", "start session",
  "init sprint", "begin feature", "pre-flight check", "check repo status before
  working", "is my repo clean?", "ready to start working", or any variation
  that implies they want to verify their repo state and create a fresh branch
  from the default branch. Also trigger when the user mentions "git-sprint-start"
  or "/sprint" explicitly. Do NOT trigger for general git questions, commit help,
  or merge/rebase guidance unless they explicitly reference starting a new session.
---

# Git Sprint Start

Structured pre-flight workflow to verify a repository is clean, synced with
the remote default branch, and ready for a new feature/fix branch.

The target user is a senior developer on a multi-contributor project. Report
findings concisely, suggest the right git operation for each situation, and
let them decide. Never auto-execute destructive operations. Never explain
basic git concepts — focus on the specific state and the shortest path to
a clean starting point.

## Critical principle: remote is the source of truth

All comparisons use `origin/<default>` as the reference point. The local
default branch is a local copy that may be stale. The diagnostic script
enforces this by running `git fetch --prune` before any comparison.

## High-level flow

```
1. Discover context    → CONTRIBUTING.md, default branch, remote
2. Fetch + diagnose    → git fetch --prune origin, then run diagnostic script
3. Report to user      → present findings, wait for confirmation
4. Act                 → pull, checkout, create branch (only after user confirms)
```

The user must confirm before any operation that modifies local branches or
the working tree. `git fetch --prune` is safe (only updates remote-tracking
refs and removes stale ones) and runs automatically in the diagnostic step.

---

## Step 1 — Discover context

### 1a. Locate the repository root

Run `git rev-parse --show-toplevel`. If this fails, inform the user and stop.

### 1b. Read CONTRIBUTING.md

Look for `CONTRIBUTING.md` (case-insensitive) at the repo root.

- **If it exists**: extract branching conventions, naming patterns, commit
  message formats. These override the defaults. Summarise the relevant
  conventions in the report.
- **If it does not exist**: use GitHub-standard conventions (see
  "Default conventions" below).

### 1c. Verify remote

Confirm the remote is `origin`. If not, warn and stop:

> ⚠️  Este repositorio no usa "origin" como remote. Se detectaron: `<list>`.
> Verifica tu configuración antes de continuar.

---

## Step 2 — Fetch and diagnose

Execute the diagnostic script:

```bash
bash <skill-dir>/scripts/diagnose.sh
```

The script runs `git fetch --prune origin` first (removing stale remote
tracking refs for branches deleted on the remote), then collects all state.

### Key diagnostic fields

**Sync layer** — local default vs remote default:

| Field                  | Meaning                                         |
|------------------------|-------------------------------------------------|
| `fetch_ok`             | Whether fetch succeeded                         |
| `local_default_synced` | Local default matches remote                    |
| `local_default_ahead`  | Commits in local default not in remote           |
| `local_default_behind` | Commits in remote not in local default           |

**HEAD layer** — current working position vs remote default:

| Field                  | Meaning                                         |
|------------------------|-------------------------------------------------|
| `head_ahead`           | Commits in HEAD not in remote default            |
| `head_behind`          | Commits HEAD is missing from remote default      |

**Workflow flags** — situations that need specific handling:

| Field                  | Meaning                                         |
|------------------------|-------------------------------------------------|
| `working_on_default`   | User is on the default branch (not a feature)    |
| `branch_merged`        | Current branch fully merged in remote default    |
| `remote_branch_exists` | Current branch still exists on the remote        |
| `stash_count`          | Number of stash entries                          |

**Working tree** — cleanliness and in-progress operations:

| Field                  | Meaning                                         |
|------------------------|-------------------------------------------------|
| `is_clean`             | No staged, modified, untracked, or conflicted    |
| `has_conflicts`        | Unmerged paths exist                             |
| `rebase_in_progress`   | Interrupted rebase                               |
| `merge_in_progress`    | Interrupted merge                                |

If `fetch_ok` is false, warn that all sync data may be stale and suggest
checking network/VPN.

---

## Step 3 — Report to the user

### Decision tree

Evaluate the diagnostic output in this order. Stop at the first match
that requires user intervention. If multiple issues exist, report all
of them grouped — don't fix one and hide the others.

#### 3.0 — Blocked states (report and stop)

These states must be resolved before anything else. Do not offer to
create a branch.

**Interrupted rebase** (`rebase_in_progress == true`):

```
🔀 Rebase en progreso con conflictos en: <conflict_files>

  Opciones:
  • Resolver conflictos → git add <files> && git rebase --continue
  • Abortar el rebase   → git rebase --abort
```

**Interrupted merge** (`merge_in_progress == true`):

```
🔀 Merge en progreso con conflictos en: <conflict_files>

  Opciones:
  • Resolver conflictos → git add <files> && git merge --continue
  • Abortar el merge    → git merge --abort
```

**Detached HEAD** (`head_detached == true`):

If clean:
```
⚠️  HEAD detached en <short-sha>. No hay rama activa.
  → git checkout <default-branch>
```

If dirty — this is urgent, work can be lost:
```
🚨 HEAD detached con cambios sin guardar. Riesgo de pérdida de trabajo.

  Archivos afectados: <list>
  Acción recomendada: crear una rama para capturar el estado actual
  → git checkout -b rescue/<descriptive-name>
  → git add -A && git commit -m "rescue: capture detached HEAD work"
```

#### 3.1 — Branch already merged

If `branch_merged == true`:

```
ℹ️  La rama "<current_branch>" ya está integrada en origin/<default>.
```

If `remote_branch_exists == false`, add:
```
    La rama remota fue eliminada (post-PR cleanup).
```

Then:
```
  → git checkout <default> && git pull origin <default>
  → git branch -d <current_branch>          # eliminar rama local
```

This is informational — the user's work is safe. Suggest cleanup and
proceed to branch creation.

#### 3.2 — Commits directly on default branch

If `working_on_default == true && local_default_ahead > 0`:

This is a workflow violation. The user committed directly on the default
branch instead of a feature branch.

```
⚠️  Hay <N> commit(s) en <default> local que no están en origin/<default>.
    Esto indica commits directos sobre la rama principal.

  Commits afectados:
    <short log of the ahead commits>
```

Show the commits with:
```bash
git log --oneline origin/<default>..HEAD
```

Then suggest the rescue pattern:

```
  Opción recomendada — mover los commits a una rama:
    git checkout -b rescue/<topic>              # rama nueva con los commits
    git checkout <default>
    git reset --hard origin/<default>           # limpiar default local

  Alternativa — si los commits son intencionados y tienes permisos de push
  directo a <default>:
    git push origin <default>
```

If `local_default_behind > 0` too (diverged), warn explicitly:

```
  ⚠️  Además, <default> local diverge de origin/<default>:
      <ahead> commit(s) locales, <behind> commit(s) remotos.

      Esto puede indicar un force-push o rebase en el remoto.

  Patrón de rescate para historias divergentes:
    git checkout -b rescue/<topic>              # salvar trabajo local
    git checkout <default>
    git reset --hard origin/<default>           # alinear con remoto
```

#### 3.3 — Uncommitted work on default branch

If `working_on_default == true && is_clean == false && local_default_ahead == 0`:

The user started working on the default branch without creating a feature
branch. Risk: accidental commit/push to the protected branch.

```
⚠️  Cambios sin commitear directamente en <default>.
    No hay rama de feature creada.

  Archivos:
    Staged:    <list or "ninguno">
    Modified:  <list or "ninguno">
    Untracked: <list or "ninguno">

  Acción recomendada — mover el trabajo a una rama nueva:
    git checkout -b <type>/<name>
    (los cambios sin commitear se preservan en la nueva rama)
```

This is the cleanest path — `git checkout -b` preserves uncommitted
changes. No stash needed.

#### 3.4 — Default branch behind remote

If `local_default_synced == false && local_default_behind > 0 && local_default_ahead == 0`:

The local default branch is simply behind the remote. Normal situation.

```
📡 <default> local está <N> commits detrás de origin/<default>.

  origin/<default>: <remote_commit>
  <default> local:  <local_commit>

  → git checkout <default> && git pull origin <default>
```

If `head_behind > 0` and on a feature branch, also note:

```
  ℹ️  Tu rama actual (<current_branch>) también está <M> commits detrás
      de origin/<default>. Después de actualizar <default>, considera
      hacer rebase:
      → git rebase <default>
```

#### 3.5 — Stash entries

If `stash_count > 0`, always mention it regardless of other state:

```
📦 Hay <N> entrada(s) en el stash:
    <stash_entries>

  Revisa si alguna es relevante para esta sesión.
  → git stash list          # ver detalle
  → git stash show -p <N>   # ver diff del entry N
  → git stash drop <N>      # eliminar si ya no es necesario
```

This goes at the end of the report, after all other sections. Stash is
informational — it doesn't block branch creation.

#### 3.6 — Everything clean

All conditions met: `is_clean`, `local_default_synced`, `head_behind == 0`,
`!working_on_default` or on default with no issues, `stash_count == 0`.

```
✅ Repositorio limpio y sincronizado

  Rama principal          : <default>
  origin/<default>        : <remote_commit>
  <default> local         : <local_commit> (sincronizada ✓)
  Working tree            : limpio
  Stash                   : vacío
  Convenciones            : <CONTRIBUTING.md | estándar GitHub>

¿Nombre para la nueva rama?
  Formato: <type>/<short-description>
  Tipos: feature | fix | hotfix | chore | docs | refactor | test | ci
```

---

## Step 4 — Create the branch (only after confirmation)

1. **Validate the branch name** against conventions. If invalid, show
   the expected format and ask again. Don't auto-correct.

2. **Update local default** (fetch already happened in Step 2):
   ```bash
   git checkout <default-branch>
   git pull origin <default-branch>
   ```

3. **Create and switch**:
   ```bash
   git checkout -b <new-branch-name>
   ```

4. **Confirm**:
   ```
   ✅ Rama creada: <branch-name>
      Base: origin/<default> (<short-sha>)
   ```

---

## Rebase vs merge guidance

When the skill suggests updating a feature branch with changes from the
default branch, prefer rebase over merge for feature branches:

- **Rebase** (`git rebase <default>`): keeps a linear history, cleaner
  for PRs. Use when the feature branch is local-only or force-push is
  acceptable on the remote feature branch.
- **Merge** (`git merge <default>`): preserves branch topology. Use when
  the feature branch is shared with other developers or has open PRs
  where force-push would disrupt reviewers.

The skill should ask which strategy the user prefers if both are viable.
Default suggestion: rebase for local branches, merge for shared branches.

---

## Default conventions (when no CONTRIBUTING.md exists)

### Branch naming

Pattern: `<type>/<short-kebab-description>`

| Type       | Use case                                    |
|------------|---------------------------------------------|
| `feature`  | New functionality                           |
| `fix`      | Bug fix                                     |
| `hotfix`   | Urgent production fix                       |
| `chore`    | Maintenance, dependencies, config           |
| `docs`     | Documentation only                          |
| `refactor` | Code restructuring without behaviour change |
| `test`     | Adding or updating tests                    |
| `ci`       | CI/CD pipeline changes                      |

Branch names: lowercase, hyphens, no special characters.
Max recommended length: 50 characters.

### Validation regex

```
^(feature|fix|hotfix|chore|docs|refactor|test|ci)/[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$
```

---

## Error handling

- **Not a git repo**: stop, inform the user.
- **No remote**: stop, suggest `git remote add origin <url>`.
- **Fetch failed**: report error, note sync data may be stale, suggest
  checking connectivity. Don't retry.
- **Detached HEAD**: see section 3.0.
- **Merge/rebase in progress**: see section 3.0.

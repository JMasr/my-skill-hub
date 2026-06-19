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

## High-level flow

```
1. Discover context   → CONTRIBUTING.md, default branch, remote
2. Diagnose state     → run diagnostic script
3. Report to user     → present findings, wait for confirmation
4. Act                → fetch, pull, create branch (only after user confirms)
```

Never skip the reporting phase. The user must confirm before any write
operation (fetch, pull, checkout, branch creation).

---

## Step 1 — Discover context

### 1a. Locate the repository root

Run `git rev-parse --show-toplevel` to find the repo root.
If this fails, tell the user the current directory is not inside a git
repository and stop.

### 1b. Read CONTRIBUTING.md

Look for `CONTRIBUTING.md` (case-insensitive) at the repo root.

- **If it exists**: read it and extract any branching conventions, naming
  patterns, commit message formats, or workflow rules. These conventions
  override the defaults below. Summarise the relevant conventions to the user
  in the report phase so they know what rules are being applied.
- **If it does not exist**: fall back to the GitHub-standard conventions
  described in the "Default conventions" section below.

### 1c. Detect the default branch

Use the diagnostic script (see Step 2). The detection order is:

1. `git symbolic-ref refs/remotes/origin/HEAD` (most reliable after a clone).
2. Check for branches named `main` or `master` on the remote.
3. Fall back to the first remote branch listed by `git branch -r`.

If none of these succeed, report the issue and stop.

### 1d. Verify remote

Confirm the remote is named `origin`. If the repo has no remote called
`origin`, or it has remotes with other names, warn the user:

> ⚠️  Este repositorio no usa "origin" como remote. Se detectaron: `<list>`.
> La skill está diseñada para trabajar con "origin". Verifica tu configuración
> antes de continuar.

Then stop and wait for the user's decision.

---

## Step 2 — Run the diagnostic script

Execute the script at `scripts/diagnose.sh` from the repo root:

```bash
bash <skill-dir>/scripts/diagnose.sh
```

The script outputs a JSON object with all the information needed for the
report. Parse it and use the fields described in the script header.

If the script exits with a non-zero code, show the raw stderr to the user
and stop.

---

## Step 3 — Report to the user

Present the findings clearly. Use this structure:

### When the repo IS clean

```
✅ Repositorio limpio y listo

  Rama principal detectada : main
  Remote                   : origin
  Estado del working tree  : limpio
  Sincronización           : al día con origin/<default-branch>
  Convenciones             : <CONTRIBUTING.md | estándar GitHub>

¿Cómo deseas nombrar la nueva rama?
Formato esperado: <type>/<short-description>
  Tipos válidos: feature, fix, hotfix, chore, docs, refactor, test, ci
  Ejemplo: feature/add-user-auth
```

If CONTRIBUTING.md defines different branch types, list those instead.

### When the repo is NOT clean

```
⚠️  Se encontraron problemas que resolver antes de continuar

  Rama actual              : <current-branch>
  Rama principal detectada : <default-branch>

  Cambios sin commitear:
    - Modified:  src/app.py
    - Untracked: notes.txt

  Estado de sincronización:
    - Local está <N> commits detrás de origin/<default-branch>
    - Local está <M> commits adelante de origin/<default-branch>

  Conflictos potenciales: <sí/no>
```

Then ask the user what they want to do. Do NOT take action automatically.
Possible options to suggest (adapt based on situation):

- Commitear los cambios pendientes antes de continuar.
- Hacer `git stash` para guardar temporalmente y continuar.
- Descartar los cambios (con advertencia de pérdida de datos).
- Resolver conflictos manualmente primero.

Wait for the user's explicit decision before doing anything.

---

## Step 4 — Create the branch (only after confirmation)

Once the user confirms and provides a branch name:

1. **Validate the branch name** against the conventions (CONTRIBUTING.md or
   defaults). If it doesn't match, show the expected format and ask again.
   Do not auto-correct silently.

2. **Fetch and update**:
   ```bash
   git fetch origin
   git checkout <default-branch>
   git pull origin <default-branch>
   ```

3. **Create and switch**:
   ```bash
   git checkout -b <new-branch-name>
   ```

4. **Final confirmation**:
   ```
   ✅ Rama creada: feature/add-user-auth
      Base: origin/main (commit abc1234)
      Estás listo para trabajar.
   ```

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

Branch names must be lowercase, use hyphens as separators, and avoid
special characters. Maximum recommended length: 50 characters total.

### Validation regex

```
^(feature|fix|hotfix|chore|docs|refactor|test|ci)/[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$
```

---

## Error handling

- **Not a git repo**: stop immediately, inform the user.
- **No remote**: stop, suggest `git remote add origin <url>`.
- **Network errors on fetch**: report the error, suggest checking connectivity
  or VPN, do not retry automatically.
- **Detached HEAD**: warn the user and suggest checking out a branch first.
- **Merge in progress**: report it and suggest completing or aborting the merge.

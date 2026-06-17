---
name: doc-updater
description: >
  Inspect a Python repository's code, git history, and existing documentation to
  identify what changed, then update docs and generate changelogs. Use whenever
  the user mentions "update docs", "sync documentation", "generate changelog",
  "what docs are outdated", "document recent changes", "write release notes",
  "refresh the README", or asks about documentation drift. Also trigger when the
  user says things like "we shipped a bunch of changes, docs need updating",
  "prep docs for the release", or "catch the docs up". Works for any Python
  project with git history — libraries, APIs, CLI tools, or applications.
---

# Doc Updater

Update documentation and generate changelogs for Python repositories by
inspecting the current codebase state and git history.

## When to Activate

### Explicit triggers
- "Update the docs"
- "Generate a changelog"
- "What documentation is outdated?"
- "Sync docs with the code"
- "Write release notes for vX.Y.Z"
- "Refresh the README"

### Implicit triggers (confirm before proceeding)
- User just merged a batch of PRs and mentions docs
- User is preparing a release
- User notices a doc file is stale or misleading

## Workflow Overview

Execute these four phases in order. Present a summary after each phase and
wait for user confirmation before continuing to the next one.

```
Phase 1: Discovery  →  Phase 2: Analysis  →  Phase 3: Update  →  Phase 4: Changelog
(what docs exist)      (what code changed)    (rewrite docs)      (write changelog)
```

The user may request only a subset of phases (e.g., "just generate the
changelog"). Skip to the relevant phase, but always run Phase 1 first —
discovery is needed for context in every other phase.

---

## Phase 1: Discovery

**Goal:** Map every documentation artifact in the repository.

Run the discovery script to get a structured inventory:

```bash
python <skill-path>/scripts/discover_docs.py --repo-root .
```

The script outputs a JSON report with:
- Root-level docs (README, CONTRIBUTING, CHANGELOG, LICENSE, etc.)
- Docs directory structure (docs/, doc/, documentation/)
- Documentation build config (Sphinx conf.py, MkDocs mkdocs.yml, etc.)
- Module-level docstrings coverage (packages with/without `__init__.py` docs)
- Key metadata files (pyproject.toml, setup.py, setup.cfg)

**After running the script:**

1. Present the inventory to the user as a concise summary table.
2. Flag any obvious gaps (e.g., no README, empty CHANGELOG, missing API docs).
3. Ask the user which documentation targets they care about for this session.
   Default to all, but let them scope it down.

If the project has no documentation at all, ask whether the user wants to
bootstrap docs from scratch (a different workflow) or just document recent
changes inline.

---

## Phase 2: Analysis

**Goal:** Identify what changed in the codebase since docs were last updated.

### Step 1: Determine the reference point

Ask the user for the comparison baseline. Common options:
- **Last tag/release** (default): `git describe --tags --abbrev=0`
- **Specific commit or tag**: user provides it
- **Date range**: `--since="2026-01-01"`
- **Last N commits**: `--max-count=50`

### Step 2: Run the analysis script

```bash
python <skill-path>/scripts/analyze_changes.py \
  --repo-root . \
  --since-ref <reference>
```

The script outputs a JSON report with:
- Commits grouped by conventional-commit type (feat, fix, refactor, docs, etc.)
- Files changed with frequency counts and change magnitude (lines added/removed)
- Public API changes detected (new/modified/removed functions, classes, modules)
- Breaking change indicators (removed public symbols, changed signatures)
- Commits that already touched documentation files

### Step 3: Cross-reference changes with existing docs

This is where Claude reasons — the scripts provide data, you provide judgment.

For each documentation target identified in Phase 1:
1. Read the current content of the document.
2. Compare it against the changes from Phase 2.
3. Classify the document status:
   - **Current**: no relevant code changes affect this doc.
   - **Stale**: code changed but doc still references old behavior.
   - **Incomplete**: new features/APIs exist with no documentation.
   - **Broken**: doc references removed code or outdated examples.

Present a status report:

```
Documentation Status Report
═══════════════════════════
  README.md .............. Stale (3 new CLI flags undocumented)
  docs/api.md ............ Broken (references removed function `parse_v1`)
  docs/quickstart.md ..... Current
  CHANGELOG.md ........... Incomplete (12 commits since last entry)
  src/core/__init__.py ... Stale (module docstring mentions old architecture)
```

Wait for user confirmation on which documents to update.

---

## Phase 3: Update

**Goal:** Rewrite each outdated document with accurate, current information.

### Before writing anything

Read `<skill-path>/references/python-doc-conventions.md` for Python-specific
documentation conventions and quality standards. Apply these conventions to
every document you write or update.

### Update protocol

Process one document at a time. For each document:

1. **Read the full current content** — understand the existing structure, tone,
   and level of detail.
2. **Identify specific sections to change** — don't rewrite what's already
   correct. Surgical edits preserve authorial voice and minimize diff noise.
3. **Draft the changes** — present a clear before/after for each section, or
   show the diff.
4. **Wait for user approval** before writing to disk. The user may want to
   adjust tone, add context, or skip a change.
5. **Apply approved changes** using targeted edits (not full-file rewrites
   unless the document needs restructuring).

### Update priorities

Process documents in this order — highest-impact first:
1. README.md (the first thing users and contributors see)
2. API reference / public interface docs
3. Guides and tutorials (quickstart, how-to)
4. Contributing / development docs
5. Module and package docstrings
6. Configuration and deployment docs

### What to update in each document type

**README.md:**
- Installation instructions (new dependencies, Python version, extras)
- Usage examples (new CLI flags, API changes, configuration options)
- Feature list (additions, removals, renames)
- Badges and metadata (version, supported Python versions)

**API reference docs:**
- New public functions, classes, methods
- Changed signatures (new params, removed params, type changes)
- Deprecated APIs (add deprecation notice with migration path)
- Removed APIs (remove the section, add note to migration guide if one exists)

**Guides and tutorials:**
- Code examples that reference changed APIs
- Workflow steps that no longer match the current behavior
- New capabilities worth demonstrating

**Module docstrings:**
- Module-level docstrings in `__init__.py` reflecting current purpose
- Class and function docstrings for changed public APIs
- Update type hints in docstring params if they drifted from code

**pyproject.toml / setup.py:**
- Classifiers matching current Python support
- Description if project scope changed

---

## Phase 4: Changelog

**Goal:** Generate structured changelog entries for the analyzed changes.

### Changelog format

Follow [Keep a Changelog](https://keepachangelog.com/) conventions:

```markdown
## [version] - YYYY-MM-DD

### Added
- New feature or capability with brief description

### Changed
- Modification to existing functionality

### Deprecated
- Feature marked for removal in a future release

### Removed
- Feature or API that was deleted

### Fixed
- Bug fix with brief description of what was wrong

### Security
- Vulnerability fix or security improvement
```

### Generating entries

1. Group the commits from Phase 2 by changelog category.
2. Write one entry per user-visible change — not one per commit. Multiple
   commits that implement the same feature collapse into one entry.
3. Lead each entry with the impact ("Users can now…", "The `parse` function
   no longer…") rather than implementation details.
4. Reference PRs or issues when available: `(#123)`.
5. Highlight breaking changes at the top of the relevant section in bold.

### Placement

- If a `CHANGELOG.md` exists, prepend the new section after the header.
- If no changelog exists, ask the user whether to create one. Don't create
  files without consent.
- For release notes (GitHub/GitLab), output the section as copyable text
  without writing a file.

### Version number

- If the user specified a version, use it.
- If not, suggest one based on the changes:
  - Breaking changes → major bump
  - New features → minor bump
  - Only fixes → patch bump
- Always let the user override.

---

## Integration Notes

### Works well alongside
- **ADR skills**: if doc updates reveal undocumented architectural decisions,
  suggest recording an ADR.
- **Code review skills**: run doc-updater after a batch of approved PRs.
- **Release skills**: chain doc update → changelog → tag → release.

### Limitations
- Does not update external documentation (wikis, hosted doc sites) — only files
  in the repository.
- Cannot infer intent from commits that lack conventional-commit prefixes; it
  will group them as "other" and ask the user to categorize.
- Docstring updates are suggested but not auto-applied without review — inline
  code changes need extra care.

---

## Error Handling

- **No git history**: the repo may be freshly initialized or a shallow clone.
  Inform the user and suggest `git fetch --unshallow` or skip Phase 2.
- **No docs at all**: offer to bootstrap a minimal doc set (README + CHANGELOG)
  instead of updating.
- **Ambiguous changes**: when a commit touches both code and docs, ask the user
  whether the doc change was complete or partial.
- **Very large diffs** (>500 changed files): suggest narrowing the scope to
  specific packages or directories rather than analyzing the entire diff.

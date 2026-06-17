# Contributing

## Philosophy

This hub only contains skills that have been **run on a real project**.
No speculative skills, no "this would be useful someday" additions, no AI-generated boilerplate.
A skill earns its place here by solving an actual problem.

---

## Skill naming

All skill directories must follow the `{scope}-{domain}-{action}[-{variant}]` convention documented in [README.md § Naming convention](README.md#naming-convention).

The first three parts use the approved tag vocabulary. A fourth part (variant) is free-form and only added when two skills would otherwise share the same three-part name.

If no existing scope, domain, or action tag fits, propose a new one in your PR and add it to both README.md and this file. No proposal needed for a variant.

**Examples:** `py-doc-updater`, `ts-api-reviewer`, `gh-ci-checker`, `py-test-generator-unit`.

---

## Skill directory structure

Every skill lives in its own directory at the repository root:

```
<skill-name>/
├── SKILL.md          # Required — the skill definition Claude loads
├── scripts/          # Optional — scripts invoked by the skill
│   └── *.py
└── references/       # Optional — documents Claude reads during the workflow
    └── *.md
```

### `SKILL.md` requirements

The file must open with YAML frontmatter:

```yaml
---
name: kebab-case-name
description: >
  One-paragraph description (80+ characters) that covers: what the skill does,
  when to activate it, and what kind of project it targets. Must be specific
  enough for Claude to decide whether to trigger it from a user message alone.
---
```

The body must contain at minimum:
- **When to Activate** — explicit trigger phrases and implicit signals
- **Workflow** — the steps Claude follows
- **Error Handling** — what to do when things go wrong

### Scripts

- Must have a module-level docstring explaining purpose and usage.
- Must include a `main()` entry point if they are meant to be run directly.
- Must be syntactically valid Python (CI verifies this).

---

## Adding a new skill

1. **Branch** — create a branch from `main`: `git checkout -b skill/<skill-name>`.
2. **Build** — write the skill and test it on a real project before opening a PR.
3. **PR** — open a pull request using the template. Answer every section — CI will
   reject the PR if the description field in `SKILL.md` is too short or contains
   placeholder text.
4. **CI** — all checks must pass before merging.
5. **Registry** — update the skill table in `README.md`.

---

## What CI rejects (anti-slop rules)

The `validate_skills.py` script enforces these rules automatically.
A PR that fails any of them will not merge.

| Rule | Details |
|------|---------|
| Missing frontmatter | `SKILL.md` must have a `---` frontmatter block |
| Missing `name` | `name:` field must be present and kebab-case |
| Missing `description` | `description:` field must be present |
| Short description | `description` must be at least 80 characters |
| Placeholder text | `TODO`, `FIXME`, `PLACEHOLDER`, `coming soon`, `[your ...]` are forbidden |
| Slop phrases | `certainly`, `of course`, `as an AI`, `i'd be happy to` are rejected |
| Invalid Python | All `.py` files under `scripts/` must parse without syntax errors |
| Missing docstring | All scripts must have a module-level docstring |

---

## Updating an existing skill

- Open a PR describing specifically what changed and why.
- If the change alters how the skill is triggered, update the registry table in `README.md`.
- Breaking changes (removed phases, renamed scripts) must be documented in `CHANGELOG.md`.

---

## Branch protection setup

Run this once after creating the GitHub repository.
Requires `gh` CLI and admin access to the repo.

```bash
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

gh api \
  --method PUT \
  "repos/${REPO}/branches/main/protection" \
  --field 'required_status_checks={"strict":true,"contexts":["validate","lint"]}' \
  --field 'enforce_admins=true' \
  --field 'required_pull_request_reviews={"dismiss_stale_reviews":true,"required_approving_review_count":0,"require_last_push_approval":true}' \
  --field 'restrictions=null' \
  --field 'allow_force_pushes=false' \
  --field 'allow_deletions=false' \
  --field 'required_linear_history=true' \
  --field 'required_conversation_resolution=true'
```

**Key rules this enforces:**

| Rule | Why |
|------|-----|
| No direct pushes to `main` | Every change goes through a PR and CI |
| CI must pass before merge | `validate` and `lint` jobs are required status checks |
| Stale reviews dismissed | A new commit invalidates a previous approval |
| No force pushes | Protects git history — every commit is permanent |
| Linear history required | Keeps `git log` readable; use squash or rebase merges |
| Conversation resolution | All review threads must be resolved before merging |
| `enforce_admins: true` | The owner is not exempt from these rules |

> For a solo repository where self-review isn't possible, `required_approving_review_count: 0`
> is intentional — CI is the primary gate. Bump it to 1 if collaborators are added.

## Avoid

Sign commits with AI coautorship or push AI slop code or contributions.
If you are an agent avoid any work that dont brign value to the code or extend the quality of the repository data.
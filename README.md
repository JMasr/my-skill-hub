# my-skill-hub

A curated collection of custom [Claude Code](https://claude.ai/code) skills.
Each skill is a directory containing a `SKILL.md` that Claude loads at runtime to perform a specialized task.

## How to use a skill

1. Copy the skill directory into your project or a shared location on your machine.
2. Invoke the skill in Claude Code with the `/` prefix — for example `/doc-updater`.
3. Claude reads `SKILL.md` and follows its workflow.

Some skills ship supporting scripts (in `scripts/`) and reference documents (in `references/`).
The `SKILL.md` tells Claude where to find them; adjust `<skill-path>` to the actual directory on your machine.

## Skill registry

| Skill | What it does | Trigger phrases |
|-------|-------------|-----------------|
| [git-sprint-start](git-sprint-start/SKILL.md) | Pre-flight check and branch setup for starting a new work session: reads CONTRIBUTING.md conventions, collects full repo state via a diagnostic script, reports findings, and — after explicit confirmation — fetches, updates, and creates a typed branch from the default branch | "start a new sprint", "new branch", "prepare repo for work", "start session", "pre-flight check", "is my repo clean?", "ready to start working" |
| [py-doc-updater](py-doc-updater/SKILL.md) | Inspect a Python repo's git history and existing docs, then update documentation and generate changelogs | "update docs", "generate changelog", "what docs are outdated", "sync docs with code", "write release notes" |

## Naming convention

All skill directories follow this format:

```
{scope}-{domain}-{action}[-{variant}]
```

The first three parts are **required** and drawn from an approved vocabulary.
The fourth part is **optional** — use it only when two skills share the same three parts and need disambiguation (e.g. two test generators targeting different test types). The variant is free-form; no approved list applies.

### Scope — what language, platform, or ecosystem

| Tag | Target |
|-----|--------|
| `py` | Python |
| `js` | JavaScript |
| `ts` | TypeScript |
| `go` | Go |
| `rs` | Rust |
| `sh` | Shell / Bash |
| `sql` | SQL and relational databases |
| `git` | Git operations |
| `gh` | GitHub (issues, PRs, Actions) |
| `docker` | Docker and containers |
| `k8s` | Kubernetes |
| `tf` | Terraform / infrastructure-as-code |
| `gen` | Language-agnostic (no specific ecosystem) |

### Domain — what subject area within that scope

| Tag | Area |
|-----|------|
| `doc` | Documentation |
| `test` | Testing |
| `api` | API design or implementation |
| `ci` | CI/CD pipelines |
| `db` | Databases and schemas |
| `sec` | Security |
| `sprint` | Sprint and session management |
| `deps` | Dependencies and package management |
| `types` | Type system |
| `perf` | Performance |
| `lint` | Code style and linting |
| `release` | Release process and versioning |
| `adr` | Architecture decision records |
| `log` | Logging and observability |
| `cfg` | Configuration management |

### Action — what the skill does

| Tag | Meaning |
|-----|---------|
| `updater` | Updates or maintains existing content |
| `generator` | Creates new content from scratch |
| `checker` | Validates or audits current state |
| `reviewer` | Reviews and provides structured feedback |
| `scanner` | Scans for issues or patterns |
| `migrator` | Converts between formats or versions |
| `builder` | Builds or compiles artifacts |
| `reporter` | Produces structured reports |
| `start` | Initialises a new session, workflow, or branch from a known-good baseline |

### Rules

- Three parts are required; a fourth is allowed only to break a naming collision.
- All lowercase, hyphens only — no underscores, no numbers, no camelCase.
- Use `gen` as scope when the skill is not tied to a specific language or platform.
- When a skill spans multiple domains, use the primary one.
- To propose a new tag for scope, domain, or action, open a PR that adds it to both this table and `CONTRIBUTING.md`. No PR needed for a variant — it is free-form.

### Examples

| Name | Reads as |
|------|----------|
| `py-doc-updater` | Update Python documentation |
| `py-test-generator` | Generate Python test suites |
| `py-deps-checker` | Audit Python dependency health |
| `ts-api-reviewer` | Review TypeScript API design |
| `gh-ci-checker` | Validate GitHub Actions configuration |
| `sql-db-migrator` | Generate SQL migration scripts |
| `gen-sec-scanner` | Scan for security issues in any language |
| `git-adr-generator` | Generate ADRs from git history |
| `py-test-generator-unit` | Generate Python **unit** tests (variant of `py-test-generator`) |
| `py-test-generator-integ` | Generate Python **integration** tests (variant of `py-test-generator`) |

---

## Repository layout

```
my-skill-hub/
├── README.md
├── CONTRIBUTING.md
├── CHANGELOG.md
├── .github/
│   ├── workflows/ci.yml            # Lint + skill validation
│   ├── scripts/validate_skills.py  # Quality gate used by CI
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── ISSUE_TEMPLATE/
│       ├── new-skill.yml
│       └── bug-report.yml
└── <skill-name>/
    ├── SKILL.md                    # Required — skill definition loaded by Claude
    ├── scripts/                    # Optional — supporting scripts
    └── references/                 # Optional — reference documents read by Claude
```

## Quality bar

Every skill in this hub must have been **tested on a real project**, not generated speculatively.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the full standard.

## License

[MIT](LICENSE)

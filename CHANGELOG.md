# Changelog

All notable changes to this repository are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `git-sprint-start`: Pre-flight skill to diagnose repository state and create a typed branch from the default branch before starting a work session.
- `gh-pm-manager`: Project-management skill for multi-repo GitHub Projects v2 (issues, backlog, ROI prioritization, sprint planning, progress reports) via the `gh` CLI.
- `gl-pm-manager`: Project-management skill for GitLab (Issues, milestones, MRs, pipelines, GitFlow releases) via the `glab` CLI.
- Naming-convention vocabulary: `sprint` domain (sprint and session management) and `start` action (initialises a session/branch from a clean baseline); `gl` scope (GitLab), `pm` domain (project management) and `manager` action (orchestrates an ongoing process without producing code).
- Ignore agent-guidance files (`CLAUDE.md`, `AGENT.md`, `AGENTS.md`) so they are never committed.

## [0.1.0] - 2026-06-18

### Added
- `py-doc-updater`: Four-phase skill to inspect Python repositories and update documentation and changelogs.
- CI workflow: skill structure validation and Python linting.
- `CONTRIBUTING.md` with quality standards and branch protection setup.

#!/usr/bin/env python3
"""Analyze git history to identify documentation-relevant changes.

Parses commits since a reference point, categorizes them by type, detects
public API changes, and flags breaking changes.

Usage:
    python analyze_changes.py --repo-root . --since-ref v1.0.0
    python analyze_changes.py --repo-root . --since-date 2026-01-01
    python analyze_changes.py --repo-root . --max-count 50
    python analyze_changes.py --repo-root . --since-ref HEAD~20 --format table
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path


# --- Conventional commit parsing ---

# Matches: "type(scope): message" or "type: message" or "type!: message"
CC_PATTERN = re.compile(
    r"^(?P<type>\w+)"
    r"(?:\((?P<scope>[^)]*)\))?"
    r"(?P<breaking>!)?"
    r":\s*(?P<message>.+)$"
)

COMMIT_TYPE_MAP = {
    "feat": "Added",
    "feature": "Added",
    "add": "Added",
    "fix": "Fixed",
    "bugfix": "Fixed",
    "hotfix": "Fixed",
    "docs": "Documentation",
    "doc": "Documentation",
    "style": "Style",
    "refactor": "Changed",
    "perf": "Changed",
    "test": "Tests",
    "tests": "Tests",
    "build": "Build",
    "ci": "CI",
    "chore": "Chore",
    "revert": "Reverted",
    "deprecate": "Deprecated",
    "remove": "Removed",
    "security": "Security",
    "breaking": "Breaking",
}


@dataclass
class CommitInfo:
    hash: str
    short_hash: str
    author: str
    date: str
    subject: str
    body: str
    commit_type: str  # Changelog category
    scope: str
    is_breaking: bool
    files_changed: list[str] = field(default_factory=list)
    insertions: int = 0
    deletions: int = 0

    def to_dict(self) -> dict:
        return {
            "hash": self.hash,
            "short_hash": self.short_hash,
            "author": self.author,
            "date": self.date,
            "subject": self.subject,
            "commit_type": self.commit_type,
            "scope": self.scope,
            "is_breaking": self.is_breaking,
            "files_changed": self.files_changed,
            "insertions": self.insertions,
            "deletions": self.deletions,
        }


@dataclass
class FileChangeStats:
    path: str
    commit_count: int
    total_insertions: int
    total_deletions: int
    is_doc_file: bool

    def to_dict(self) -> dict:
        return {
            "path": self.path,
            "commit_count": self.commit_count,
            "total_insertions": self.total_insertions,
            "total_deletions": self.total_deletions,
            "is_doc_file": self.is_doc_file,
        }


@dataclass
class PublicAPIChange:
    """A detected change to a public Python symbol."""

    kind: str  # "added" | "modified" | "removed"
    symbol_type: str  # "function" | "class" | "module"
    name: str
    file: str

    def to_dict(self) -> dict:
        return {
            "kind": self.kind,
            "symbol_type": self.symbol_type,
            "name": self.name,
            "file": self.file,
        }


@dataclass
class AnalysisReport:
    reference_point: str
    total_commits: int
    date_range: dict  # {from, to}
    commits_by_type: dict[str, list[dict]] = field(default_factory=dict)
    file_stats: list[FileChangeStats] = field(default_factory=list)
    api_changes: list[PublicAPIChange] = field(default_factory=list)
    breaking_changes: list[dict] = field(default_factory=list)
    doc_commits: list[dict] = field(default_factory=list)
    authors: list[dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "reference_point": self.reference_point,
            "total_commits": self.total_commits,
            "date_range": self.date_range,
            "commits_by_type": self.commits_by_type,
            "file_stats": [f.to_dict() for f in self.file_stats],
            "api_changes": [a.to_dict() for a in self.api_changes],
            "breaking_changes": self.breaking_changes,
            "doc_commits": self.doc_commits,
            "authors": self.authors,
        }


DOC_EXTENSIONS = {".md", ".rst", ".txt", ".html", ".ipynb"}
DOC_FILENAMES = {
    "readme",
    "changelog",
    "changes",
    "history",
    "contributing",
    "code_of_conduct",
    "license",
    "security",
    "migration",
    "upgrade",
    "authors",
    "todo",
}


def _is_doc_file(filepath: str) -> bool:
    """Determine if a file path is a documentation file."""
    p = Path(filepath)
    # Docs directory
    if any(part in {"docs", "doc", "documentation"} for part in p.parts):
        return True
    # Root doc files
    if p.stem.lower() in DOC_FILENAMES:
        return True
    # Doc extensions at root level
    if len(p.parts) == 1 and p.suffix.lower() in DOC_EXTENSIONS:
        return True
    return False


def _run_git(repo_root: Path, args: list[str]) -> str:
    """Execute a git command and return stdout."""
    result = subprocess.run(
        ["git", "-C", str(repo_root)] + args,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def _parse_commit_type(subject: str, body: str) -> tuple[str, str, bool]:
    """Parse conventional commit prefix and detect breaking changes."""
    match = CC_PATTERN.match(subject)
    if match:
        raw_type = match.group("type").lower()
        scope = match.group("scope") or ""
        is_breaking = bool(match.group("breaking"))
        commit_type = COMMIT_TYPE_MAP.get(raw_type, "Other")
    else:
        scope = ""
        is_breaking = False
        commit_type = _infer_type_from_subject(subject)

    # Check body for BREAKING CHANGE footer
    if "BREAKING CHANGE" in body or "BREAKING-CHANGE" in body:
        is_breaking = True

    return commit_type, scope, is_breaking


def _infer_type_from_subject(subject: str) -> str:
    """Best-effort type inference for non-conventional commits."""
    lower = subject.lower()
    if any(w in lower for w in ("add", "new", "implement", "introduce", "create")):
        return "Added"
    if any(w in lower for w in ("fix", "bug", "patch", "resolve", "correct")):
        return "Fixed"
    if any(w in lower for w in ("remove", "delete", "drop")):
        return "Removed"
    if any(w in lower for w in ("refactor", "restructure", "reorganize", "rename")):
        return "Changed"
    if any(w in lower for w in ("deprecat",)):
        return "Deprecated"
    if any(w in lower for w in ("doc", "readme", "changelog")):
        return "Documentation"
    if any(w in lower for w in ("test",)):
        return "Tests"
    if any(w in lower for w in ("ci", "github action", "pipeline", "workflow")):
        return "CI"
    if any(w in lower for w in ("security", "vulnerab", "cve")):
        return "Security"
    return "Other"


def parse_commits(repo_root: Path, git_log_args: list[str]) -> list[CommitInfo]:
    """Parse git log into structured commit objects.

    Uses a two-pass approach: first get commit metadata, then file stats.
    This avoids the fragile interleaving of --format and --numstat.
    """
    # Null byte as field separator, record separator between commits
    field_sep = "%x00"
    record_sep = "%x01"
    fmt = f"{field_sep.join(['%H', '%h', '%an', '%ai', '%s', '%b'])}{record_sep}"

    raw = _run_git(repo_root, ["log", f"--format={fmt}"] + git_log_args)
    if not raw:
        return []

    # Get per-commit file lists separately (one commit per block, blank-line separated)
    try:
        numstat_raw = _run_git(
            repo_root,
            [
                "log",
                "--format=%x01%H",
                "--numstat",
            ]
            + git_log_args,
        )
    except RuntimeError:
        numstat_raw = ""

    # Build a map: commit_hash -> (files, insertions, deletions)
    file_map: dict[str, tuple[list[str], int, int]] = {}
    if numstat_raw:
        for block in numstat_raw.split("\x01"):
            block = block.strip()
            if not block:
                continue
            lines = block.splitlines()
            commit_hash = lines[0].strip()
            files = []
            insertions = 0
            deletions = 0
            for line in lines[1:]:
                parts = line.split("\t")
                if len(parts) == 3:
                    try:
                        ins = int(parts[0]) if parts[0] != "-" else 0
                        dels = int(parts[1]) if parts[1] != "-" else 0
                        insertions += ins
                        deletions += dels
                        files.append(parts[2])
                    except ValueError:
                        continue
            file_map[commit_hash] = (files, insertions, deletions)

    commits = []
    for record in raw.split("\x01"):
        record = record.strip()
        if not record:
            continue

        fields = record.split("\x00")
        if len(fields) < 5:
            continue

        hash_full = fields[0].strip()
        short_hash = fields[1].strip()
        author = fields[2].strip()
        date = fields[3].strip()
        subject = fields[4].strip()
        body = fields[5].strip() if len(fields) > 5 else ""

        commit_type, scope, is_breaking = _parse_commit_type(subject, body)

        files, insertions, deletions = file_map.get(hash_full, ([], 0, 0))

        commits.append(
            CommitInfo(
                hash=hash_full,
                short_hash=short_hash,
                author=author,
                date=date[:10],  # YYYY-MM-DD
                subject=subject,
                body=body,
                commit_type=commit_type,
                scope=scope,
                is_breaking=is_breaking,
                files_changed=files,
                insertions=insertions,
                deletions=deletions,
            )
        )

    return commits


def compute_file_stats(commits: list[CommitInfo]) -> list[FileChangeStats]:
    """Aggregate per-file change statistics across all commits."""
    stats: dict[str, dict] = {}

    for commit in commits:
        for filepath in commit.files_changed:
            if filepath not in stats:
                stats[filepath] = {
                    "commit_count": 0,
                    "total_insertions": 0,
                    "total_deletions": 0,
                }
            stats[filepath]["commit_count"] += 1
            # We don't have per-file ins/del from the commit object,
            # so we approximate from total — this is a simplification.
            # For precise per-file stats we'd need a second git call.

    # Re-run with per-file precision using shortstat would be expensive.
    # Keep the commit count which is the most useful metric.
    return sorted(
        [
            FileChangeStats(
                path=path,
                commit_count=s["commit_count"],
                total_insertions=s["total_insertions"],
                total_deletions=s["total_deletions"],
                is_doc_file=_is_doc_file(path),
            )
            for path, s in stats.items()
        ],
        key=lambda x: x.commit_count,
        reverse=True,
    )


def detect_api_changes(repo_root: Path, reference: str) -> list[PublicAPIChange]:
    """Detect public API changes by comparing Python symbols before/after.

    Compares exported names in __init__.py and public module-level definitions
    between the reference point and HEAD.
    """
    changes = []

    # Get list of changed .py files
    try:
        diff_output = _run_git(
            repo_root,
            [
                "diff",
                "--name-only",
                "--diff-filter=ADMR",
                reference,
                "HEAD",
                "--",
                "*.py",
            ],
        )
    except RuntimeError:
        return changes

    if not diff_output:
        return changes

    changed_files = diff_output.splitlines()

    for filepath in changed_files:
        full_path = repo_root / filepath
        if not full_path.exists():
            # File was deleted
            changes.append(
                PublicAPIChange(
                    kind="removed",
                    symbol_type="module",
                    name=filepath,
                    file=filepath,
                )
            )
            continue

        # Check if this is a new file
        try:
            _run_git(repo_root, ["cat-file", "-e", f"{reference}:{filepath}"])
            is_new = False
        except RuntimeError:
            is_new = True

        if is_new:
            # Extract public symbols from the new file
            try:
                source = full_path.read_text(errors="replace")
                tree = ast.parse(source)
            except (SyntaxError, ValueError):
                continue

            for node in ast.iter_child_nodes(tree):
                if isinstance(
                    node, (ast.FunctionDef, ast.AsyncFunctionDef)
                ) and not node.name.startswith("_"):
                    changes.append(
                        PublicAPIChange(
                            kind="added",
                            symbol_type="function",
                            name=node.name,
                            file=filepath,
                        )
                    )
                elif isinstance(node, ast.ClassDef) and not node.name.startswith("_"):
                    changes.append(
                        PublicAPIChange(
                            kind="added",
                            symbol_type="class",
                            name=node.name,
                            file=filepath,
                        )
                    )
        else:
            # Compare old vs new public symbols
            try:
                old_source = _run_git(repo_root, ["show", f"{reference}:{filepath}"])
                new_source = full_path.read_text(errors="replace")
                old_symbols = _extract_public_symbols_typed(old_source)
                new_symbols = _extract_public_symbols_typed(new_source)

                old_names = set(old_symbols.keys())
                new_names = set(new_symbols.keys())

                for name in new_names - old_names:
                    changes.append(
                        PublicAPIChange(
                            kind="added",
                            symbol_type=new_symbols[name],
                            name=name,
                            file=filepath,
                        )
                    )
                for name in old_names - new_names:
                    changes.append(
                        PublicAPIChange(
                            kind="removed",
                            symbol_type=old_symbols[name],
                            name=name,
                            file=filepath,
                        )
                    )
            except (RuntimeError, SyntaxError, ValueError):
                # Modified but we can't parse — flag as modified
                changes.append(
                    PublicAPIChange(
                        kind="modified",
                        symbol_type="module",
                        name=filepath,
                        file=filepath,
                    )
                )

    return changes[:100]  # Cap output for very large diffs


def _extract_public_symbols(source: str) -> set[str]:
    """Extract public (non-underscore-prefixed) top-level symbol names."""
    return set(_extract_public_symbols_typed(source).keys())


def _extract_public_symbols_typed(source: str) -> dict[str, str]:
    """Extract public top-level symbols with their type (function/class/variable)."""
    try:
        tree = ast.parse(source)
    except (SyntaxError, ValueError):
        return {}

    symbols: dict[str, str] = {}
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if not node.name.startswith("_"):
                symbols[node.name] = "function"
        elif isinstance(node, ast.ClassDef):
            if not node.name.startswith("_"):
                symbols[node.name] = "class"
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and not target.id.startswith("_"):
                    symbols[target.id] = "variable"

    return symbols


def build_report(
    commits: list[CommitInfo],
    file_stats: list[FileChangeStats],
    api_changes: list[PublicAPIChange],
    reference: str,
) -> AnalysisReport:
    """Assemble the full analysis report."""

    # Group commits by type
    by_type: dict[str, list[dict]] = {}
    for commit in commits:
        by_type.setdefault(commit.commit_type, []).append(commit.to_dict())

    # Extract breaking changes
    breaking = [c.to_dict() for c in commits if c.is_breaking]

    # Extract doc-touching commits
    doc_commits = [
        c.to_dict() for c in commits if any(_is_doc_file(f) for f in c.files_changed)
    ]

    # Author stats
    author_counts: dict[str, int] = {}
    for c in commits:
        author_counts[c.author] = author_counts.get(c.author, 0) + 1
    authors = sorted(
        [{"name": k, "commits": v} for k, v in author_counts.items()],
        key=lambda x: x["commits"],
        reverse=True,
    )

    # Date range
    dates = [c.date for c in commits if c.date]
    date_range = {
        "from": min(dates) if dates else "unknown",
        "to": max(dates) if dates else "unknown",
    }

    return AnalysisReport(
        reference_point=reference,
        total_commits=len(commits),
        date_range=date_range,
        commits_by_type=by_type,
        file_stats=file_stats[:30],  # Top 30 most-changed files
        api_changes=api_changes,
        breaking_changes=breaking,
        doc_commits=doc_commits,
        authors=authors,
    )


def format_table(report: AnalysisReport) -> str:
    """Format the report as a human-readable table."""
    lines = [
        "",
        "Change Analysis Report",
        "=" * 60,
        f"Reference: {report.reference_point}",
        f"Period: {report.date_range['from']} → {report.date_range['to']}",
        f"Total commits: {report.total_commits}",
        "",
    ]

    # Commits by type
    lines.append("Commits by Type:")
    lines.append("-" * 40)
    for ctype, commits in sorted(report.commits_by_type.items()):
        lines.append(f"  {ctype:<20} {len(commits):>4} commits")
    lines.append("")

    # Breaking changes
    if report.breaking_changes:
        lines.append("⚠  Breaking Changes:")
        lines.append("-" * 40)
        for bc in report.breaking_changes:
            lines.append(f"  {bc['short_hash']} {bc['subject']}")
        lines.append("")

    # API changes
    if report.api_changes:
        lines.append("Public API Changes:")
        lines.append("-" * 40)
        for ac in report.api_changes:
            icon = {"added": "+", "removed": "-", "modified": "~"}[ac.kind]
            lines.append(f"  [{icon}] {ac.symbol_type} {ac.name}  ({ac.file})")
        lines.append("")

    # Most changed files
    lines.append("Most Changed Files (top 15):")
    lines.append("-" * 40)
    for fs in report.file_stats[:15]:
        doc_tag = " [doc]" if fs.is_doc_file else ""
        lines.append(f"  {fs.path:<45} {fs.commit_count:>3} commits{doc_tag}")
    lines.append("")

    # Authors
    lines.append("Contributors:")
    lines.append("-" * 40)
    for a in report.authors[:10]:
        lines.append(f"  {a['name']:<30} {a['commits']:>4} commits")
    lines.append("")

    # Doc commits
    if report.doc_commits:
        lines.append(f"Commits touching documentation: {len(report.doc_commits)}")
    else:
        lines.append("⚠  No commits touched documentation files in this period.")
    lines.append("")

    return "\n".join(lines)


def resolve_reference(
    repo_root: Path, args: argparse.Namespace
) -> tuple[str, list[str]]:
    """Resolve the reference point into git log arguments."""
    if args.since_ref:
        ref = args.since_ref
        return ref, [f"{ref}..HEAD"]
    elif args.since_date:
        return f"since {args.since_date}", [f"--since={args.since_date}"]
    elif args.max_count:
        return f"last {args.max_count} commits", [f"--max-count={args.max_count}"]
    else:
        # Default: since last tag
        try:
            last_tag = _run_git(repo_root, ["describe", "--tags", "--abbrev=0"])
            return last_tag, [f"{last_tag}..HEAD"]
        except RuntimeError:
            # No tags — last 50 commits
            return "last 50 commits", ["--max-count=50"]


def run(repo_root: Path, args: argparse.Namespace, output_format: str = "json") -> str:
    """Execute the full analysis."""
    reference, log_args = resolve_reference(repo_root, args)

    commits = parse_commits(repo_root, log_args)
    if not commits:
        return json.dumps(
            {
                "reference_point": reference,
                "total_commits": 0,
                "message": "No commits found in the specified range.",
            },
            indent=2,
        )

    file_stats = compute_file_stats(commits)

    # API change detection needs a concrete ref for git diff
    api_ref = args.since_ref if args.since_ref else None
    api_changes = []
    if api_ref:
        try:
            api_changes = detect_api_changes(repo_root, api_ref)
        except RuntimeError:
            pass  # Non-fatal — report without API changes

    report = build_report(commits, file_stats, api_changes, reference)

    if output_format == "table":
        return format_table(report)
    return json.dumps(report.to_dict(), indent=2)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Analyze git history for documentation-relevant changes."
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path("."),
        help="Path to the repository root.",
    )
    ref_group = parser.add_mutually_exclusive_group()
    ref_group.add_argument(
        "--since-ref",
        type=str,
        help="Git reference (tag, commit, branch) to compare against HEAD.",
    )
    ref_group.add_argument(
        "--since-date",
        type=str,
        help="Analyze commits since this date (YYYY-MM-DD).",
    )
    ref_group.add_argument(
        "--max-count",
        type=int,
        help="Analyze the last N commits.",
    )
    parser.add_argument(
        "--format",
        choices=["json", "table"],
        default="json",
        help="Output format.",
    )
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    if not (repo_root / ".git").exists():
        print("Error: not a git repository.", file=sys.stderr)
        sys.exit(1)

    print(run(repo_root, args, args.format))


if __name__ == "__main__":
    main()

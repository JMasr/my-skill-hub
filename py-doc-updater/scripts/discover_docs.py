#!/usr/bin/env python3
"""Discover documentation artifacts in a Python repository.

Walks the repository tree and produces a structured JSON inventory of all
documentation files, build configs, and docstring coverage metadata.

Usage:
    python discover_docs.py --repo-root /path/to/repo
    python discover_docs.py --repo-root . --format table
"""

from __future__ import annotations

import argparse
import ast
import json
import sys
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path


class DocStatus(str, Enum):
    PRESENT = "present"
    EMPTY = "empty"
    MISSING = "missing"


@dataclass
class DocFile:
    path: str
    status: DocStatus
    size_bytes: int = 0
    line_count: int = 0

    def to_dict(self) -> dict:
        return {
            "path": self.path,
            "status": self.status.value,
            "size_bytes": self.size_bytes,
            "line_count": self.line_count,
        }


@dataclass
class DocstringCoverage:
    package: str
    has_init_docstring: bool
    module_count: int
    modules_with_docstrings: int

    @property
    def coverage_pct(self) -> float:
        if self.module_count == 0:
            return 0.0
        return round(self.modules_with_docstrings / self.module_count * 100, 1)

    def to_dict(self) -> dict:
        return {
            "package": self.package,
            "has_init_docstring": self.has_init_docstring,
            "module_count": self.module_count,
            "modules_with_docstrings": self.modules_with_docstrings,
            "coverage_pct": self.coverage_pct,
        }


@dataclass
class DocInventory:
    root_docs: list[DocFile] = field(default_factory=list)
    doc_directories: list[dict] = field(default_factory=list)
    build_configs: list[DocFile] = field(default_factory=list)
    docstring_coverage: list[DocstringCoverage] = field(default_factory=list)
    metadata_files: list[DocFile] = field(default_factory=list)
    gaps: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "root_docs": [d.to_dict() for d in self.root_docs],
            "doc_directories": self.doc_directories,
            "build_configs": [d.to_dict() for d in self.build_configs],
            "docstring_coverage": [d.to_dict() for d in self.docstring_coverage],
            "metadata_files": [d.to_dict() for d in self.metadata_files],
            "gaps": self.gaps,
        }


# Files typically found at the repo root that count as documentation.
ROOT_DOC_NAMES = [
    "README.md",
    "README.rst",
    "README.txt",
    "README",
    "CHANGELOG.md",
    "CHANGELOG.rst",
    "CHANGES.md",
    "CHANGES.rst",
    "HISTORY.md",
    "HISTORY.rst",
    "CONTRIBUTING.md",
    "CONTRIBUTING.rst",
    "CODE_OF_CONDUCT.md",
    "LICENSE",
    "LICENSE.md",
    "LICENSE.txt",
    "SECURITY.md",
    "MIGRATION.md",
    "UPGRADE.md",
    "AUTHORS.md",
    "AUTHORS",
]

DOC_DIR_NAMES = {"docs", "doc", "documentation", "wiki"}

BUILD_CONFIG_PATTERNS = {
    "conf.py": "sphinx",
    "mkdocs.yml": "mkdocs",
    "mkdocs.yaml": "mkdocs",
    ".readthedocs.yml": "readthedocs",
    ".readthedocs.yaml": "readthedocs",
    "docusaurus.config.js": "docusaurus",
    "docusaurus.config.ts": "docusaurus",
}

METADATA_FILES = [
    "pyproject.toml",
    "setup.py",
    "setup.cfg",
]

SKIP_DIRS = {
    ".git",
    ".hg",
    ".svn",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "node_modules",
    ".tox",
    ".nox",
    ".venv",
    "venv",
    "env",
    ".eggs",
    "*.egg-info",
    "build",
    "dist",
}


def _check_file(repo_root: Path, filename: str) -> DocFile:
    """Check if a file exists and return its metadata."""
    path = repo_root / filename
    if not path.exists():
        return DocFile(path=filename, status=DocStatus.MISSING)
    content = path.read_text(errors="replace")
    if not content.strip():
        return DocFile(
            path=filename,
            status=DocStatus.EMPTY,
            size_bytes=path.stat().st_size,
            line_count=0,
        )
    return DocFile(
        path=filename,
        status=DocStatus.PRESENT,
        size_bytes=path.stat().st_size,
        line_count=len(content.splitlines()),
    )


def _should_skip(dir_path: Path) -> bool:
    """Check if a directory should be skipped during traversal."""
    name = dir_path.name
    return name in SKIP_DIRS or name.endswith(".egg-info")


def discover_root_docs(repo_root: Path) -> list[DocFile]:
    """Find standard documentation files at the repository root."""
    results = []
    for name in ROOT_DOC_NAMES:
        doc = _check_file(repo_root, name)
        if doc.status != DocStatus.MISSING:
            results.append(doc)
    return results


def discover_doc_directories(repo_root: Path) -> list[dict]:
    """Find documentation directories and catalog their contents."""
    directories = []
    for name in DOC_DIR_NAMES:
        doc_dir = repo_root / name
        if not doc_dir.is_dir():
            continue

        files = []
        for f in sorted(doc_dir.rglob("*")):
            if f.is_file() and f.suffix in {".md", ".rst", ".txt", ".html", ".ipynb"}:
                rel = str(f.relative_to(repo_root))
                files.append(rel)

        directories.append(
            {
                "directory": name,
                "file_count": len(files),
                "files": files[:50],  # Cap to avoid giant outputs
                "truncated": len(files) > 50,
            }
        )

    return directories


def discover_build_configs(repo_root: Path) -> list[DocFile]:
    """Find documentation build system configurations."""
    results = []
    for pattern, system in BUILD_CONFIG_PATTERNS.items():
        # Search root and docs/ directories
        for search_root in [repo_root] + [repo_root / d for d in DOC_DIR_NAMES]:
            path = search_root / pattern
            if path.is_file():
                doc = DocFile(
                    path=str(path.relative_to(repo_root)),
                    status=DocStatus.PRESENT,
                    size_bytes=path.stat().st_size,
                    line_count=len(path.read_text(errors="replace").splitlines()),
                )
                results.append(doc)
    return results


def _has_module_docstring(filepath: Path) -> bool:
    """Check if a Python file has a module-level docstring."""
    try:
        source = filepath.read_text(errors="replace")
        tree = ast.parse(source)
        return ast.get_docstring(tree) is not None
    except (SyntaxError, ValueError):
        return False


def discover_docstring_coverage(repo_root: Path) -> list[DocstringCoverage]:
    """Analyze docstring coverage for Python packages in the repository."""
    coverages = []

    # Find Python packages (directories with __init__.py)
    for init_path in sorted(repo_root.rglob("__init__.py")):
        # Skip virtual envs and build artifacts
        if any(_should_skip(p) for p in init_path.relative_to(repo_root).parents):
            continue

        pkg_dir = init_path.parent
        pkg_name = str(pkg_dir.relative_to(repo_root))

        # Only top-level and one-deep packages to keep output concise
        depth = len(pkg_dir.relative_to(repo_root).parts)
        if depth > 2:
            continue

        has_init_doc = _has_module_docstring(init_path)

        # Count .py files in this package (non-recursive for this level)
        py_files = [f for f in pkg_dir.glob("*.py") if f.name != "__init__.py"]
        modules_with_docs = sum(1 for f in py_files if _has_module_docstring(f))

        coverages.append(
            DocstringCoverage(
                package=pkg_name,
                has_init_docstring=has_init_doc,
                module_count=len(py_files),
                modules_with_docstrings=modules_with_docs,
            )
        )

    return coverages


def discover_metadata(repo_root: Path) -> list[DocFile]:
    """Find project metadata files."""
    results = []
    for name in METADATA_FILES:
        doc = _check_file(repo_root, name)
        if doc.status != DocStatus.MISSING:
            results.append(doc)
    return results


def identify_gaps(inventory: DocInventory) -> list[str]:
    """Identify documentation gaps and common issues."""
    gaps = []

    # Check for missing essential docs
    root_paths = {d.path.upper() for d in inventory.root_docs}
    if not any(p.startswith("README") for p in root_paths):
        gaps.append("No README file found — this is critical for any project.")

    if not any(
        "CHANGELOG" in p or "CHANGES" in p or "HISTORY" in p for p in root_paths
    ):
        gaps.append("No CHANGELOG/CHANGES/HISTORY file found.")

    if not any("CONTRIBUTING" in p for p in root_paths):
        gaps.append(
            "No CONTRIBUTING file found (recommended for open-source projects)."
        )

    # Check for empty docs
    for doc in inventory.root_docs:
        if doc.status == DocStatus.EMPTY:
            gaps.append(f"{doc.path} exists but is empty.")

    # Check for missing doc directories
    if not inventory.doc_directories:
        gaps.append(
            "No docs/ directory found — consider adding structured documentation."
        )

    # Check docstring coverage
    for cov in inventory.docstring_coverage:
        if not cov.has_init_docstring:
            gaps.append(f"Package '{cov.package}' has no __init__.py docstring.")
        if cov.module_count > 0 and cov.coverage_pct < 50:
            gaps.append(
                f"Package '{cov.package}' has low docstring coverage "
                f"({cov.coverage_pct}% — {cov.modules_with_docstrings}/{cov.module_count} modules)."
            )

    # Check for build config without docs
    if inventory.build_configs and not inventory.doc_directories:
        gaps.append("Documentation build config found but no docs/ directory exists.")

    return gaps


def format_table(inventory: DocInventory) -> str:
    """Format the inventory as a human-readable table."""
    lines = ["", "Documentation Inventory", "=" * 60, ""]

    # Root docs
    lines.append("Root Documentation Files:")
    lines.append("-" * 40)
    for doc in inventory.root_docs:
        status_icon = "✓" if doc.status == DocStatus.PRESENT else "⚠ empty"
        lines.append(f"  {doc.path:<30} {status_icon}  ({doc.line_count} lines)")
    if not inventory.root_docs:
        lines.append("  (none found)")
    lines.append("")

    # Doc directories
    lines.append("Documentation Directories:")
    lines.append("-" * 40)
    for d in inventory.doc_directories:
        lines.append(f"  {d['directory']}/  ({d['file_count']} files)")
        for f in d["files"][:10]:
            lines.append(f"    └── {f}")
        if d["file_count"] > 10:
            lines.append(f"    └── ... and {d['file_count'] - 10} more")
    if not inventory.doc_directories:
        lines.append("  (none found)")
    lines.append("")

    # Build configs
    if inventory.build_configs:
        lines.append("Build Configurations:")
        lines.append("-" * 40)
        for doc in inventory.build_configs:
            lines.append(f"  {doc.path}")
        lines.append("")

    # Docstring coverage
    if inventory.docstring_coverage:
        lines.append("Docstring Coverage:")
        lines.append("-" * 40)
        for cov in inventory.docstring_coverage:
            init_icon = "✓" if cov.has_init_docstring else "✗"
            lines.append(
                f"  {cov.package:<30} init: {init_icon}  "
                f"modules: {cov.modules_with_docstrings}/{cov.module_count} "
                f"({cov.coverage_pct}%)"
            )
        lines.append("")

    # Metadata
    if inventory.metadata_files:
        lines.append("Metadata Files:")
        lines.append("-" * 40)
        for doc in inventory.metadata_files:
            lines.append(f"  {doc.path}")
        lines.append("")

    # Gaps
    if inventory.gaps:
        lines.append("⚠  Documentation Gaps:")
        lines.append("-" * 40)
        for gap in inventory.gaps:
            lines.append(f"  • {gap}")
        lines.append("")

    return "\n".join(lines)


def run(repo_root: Path, output_format: str = "json") -> str:
    """Execute the full discovery and return formatted output."""
    inventory = DocInventory(
        root_docs=discover_root_docs(repo_root),
        doc_directories=discover_doc_directories(repo_root),
        build_configs=discover_build_configs(repo_root),
        docstring_coverage=discover_docstring_coverage(repo_root),
        metadata_files=discover_metadata(repo_root),
    )
    inventory.gaps = identify_gaps(inventory)

    if output_format == "table":
        return format_table(inventory)
    return json.dumps(inventory.to_dict(), indent=2)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Discover documentation artifacts in a Python repository."
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path("."),
        help="Path to the repository root (default: current directory).",
    )
    parser.add_argument(
        "--format",
        choices=["json", "table"],
        default="json",
        help="Output format (default: json).",
    )
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    if not repo_root.is_dir():
        print(f"Error: {repo_root} is not a directory.", file=sys.stderr)
        sys.exit(1)

    print(run(repo_root, args.format))


if __name__ == "__main__":
    main()

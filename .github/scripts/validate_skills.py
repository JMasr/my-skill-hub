#!/usr/bin/env python3
"""Validate all skill directories in the hub.

Checks that each skill directory contains a valid SKILL.md with proper
frontmatter, a substantive description, no placeholder text, and (if present)
syntactically valid Python scripts with module-level docstrings.

Exit code 0 means all skills are valid. Exit code 1 means at least one
validation error was found; all errors are printed before exiting.

Usage:
    python .github/scripts/validate_skills.py [--root .]
"""

from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path

# Directories that are never skill directories.
_SKIP_DIRS = {
    ".git",
    ".github",
    ".venv",
    "venv",
    "env",
    "__pycache__",
    ".mypy_cache",
    ".ruff_cache",
    ".pytest_cache",
    "node_modules",
    "dist",
    "build",
}

# Phrases that indicate AI-generated boilerplate or placeholder content.
_SLOP_PHRASES = [
    "certainly",
    "of course",
    "as an ai",
    "as an artificial intelligence",
    "i'd be happy to",
    "i would be happy to",
    "lorem ipsum",
]

# Patterns that indicate unfilled placeholder text.
_PLACEHOLDER_PATTERNS = [
    re.compile(r"\bTODO\b"),
    re.compile(r"\bFIXME\b"),
    re.compile(r"\bPLACEHOLDER\b", re.IGNORECASE),
    re.compile(r"coming soon", re.IGNORECASE),
    re.compile(r"\[your ", re.IGNORECASE),
    re.compile(r"description here", re.IGNORECASE),
    re.compile(r"\bTBD\b"),
]

_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)
_NAME_RE = re.compile(r"^name\s*:\s*(.+)$", re.MULTILINE)
_DESC_BLOCK_RE = re.compile(
    r"^description\s*:\s*(?:>|>-|\|)[ \t]*\n((?:[ \t]+\S.*\n?)+)", re.MULTILINE
)
_DESC_INLINE_RE = re.compile(r"^description\s*:\s*(\S.+)$", re.MULTILINE)
_KEBAB_RE = re.compile(r"^[a-z][a-z0-9-]*$")
# Naming convention: {scope}-{domain}-{action}[-{variant}]
# Three parts required; fourth is optional and free-form (no approved list).
_NAMING_RE = re.compile(r"^[a-z][a-z0-9]+-[a-z][a-z0-9]+-[a-z][a-z0-9]+(?:-[a-z][a-z0-9]+)?$")

# Approved scope, domain, and action tags (from README § Naming convention).
_APPROVED_SCOPES = {
    "py",
    "js",
    "ts",
    "go",
    "rs",
    "sh",
    "sql",
    "git",
    "gh",
    "gl",
    "docker",
    "k8s",
    "tf",
    "gen",
}
_APPROVED_DOMAINS = {
    "doc",
    "test",
    "api",
    "ci",
    "db",
    "sec",
    "sprint",
    "pm",
    "deps",
    "types",
    "perf",
    "lint",
    "release",
    "adr",
    "log",
    "cfg",
}
_APPROVED_ACTIONS = {
    "updater",
    "generator",
    "checker",
    "reviewer",
    "scanner",
    "migrator",
    "builder",
    "reporter",
    "manager",
    "start",
}

MIN_DESCRIPTION_CHARS = 80
MIN_BODY_CHARS = 200


class Error:
    def __init__(self, skill: str, message: str) -> None:
        self.skill = skill
        self.message = message

    def __str__(self) -> str:
        return f"  [{self.skill}] {self.message}"


def find_skill_dirs(root: Path) -> list[Path]:
    """Return all immediate subdirectories of root that contain SKILL.md."""
    skills = []
    for entry in sorted(root.iterdir()):
        if not entry.is_dir():
            continue
        if entry.name in _SKIP_DIRS or entry.name.startswith("."):
            continue
        if (entry / "SKILL.md").is_file():
            skills.append(entry)
    return skills


def parse_frontmatter(content: str) -> dict[str, str] | None:
    """Extract frontmatter fields from SKILL.md content. Returns None if missing."""
    match = _FRONTMATTER_RE.match(content)
    if not match:
        return None
    block = match.group(1)
    fields: dict[str, str] = {}

    name_m = _NAME_RE.search(block)
    if name_m:
        fields["name"] = name_m.group(1).strip().strip("\"'")

    # Description can be a multi-line block scalar (> or |) or inline.
    block_m = _DESC_BLOCK_RE.search(block)
    if block_m:
        raw = block_m.group(1)
        lines = [line.strip() for line in raw.splitlines() if line.strip()]
        fields["description"] = " ".join(lines)
    else:
        inline_m = _DESC_INLINE_RE.search(block)
        if inline_m:
            fields["description"] = inline_m.group(1).strip()

    return fields


def check_for_slop(text: str, skill: str, location: str) -> list[Error]:
    """Return errors for any slop phrases found in text."""
    errors = []
    lower = text.lower()
    for phrase in _SLOP_PHRASES:
        if phrase in lower:
            errors.append(Error(skill, f"{location}: contains slop phrase '{phrase}'"))
    return errors


def check_for_placeholders(text: str, skill: str, location: str) -> list[Error]:
    """Return errors for any placeholder patterns found in text."""
    errors = []
    for pattern in _PLACEHOLDER_PATTERNS:
        if pattern.search(text):
            errors.append(
                Error(
                    skill,
                    f"{location}: contains placeholder text matching '{pattern.pattern}'",
                )
            )
    return errors


def validate_directory_name(skill_name: str) -> list[Error]:
    """Check the directory follows the {scope}-{domain}-{action}[-{variant}] convention."""
    errors = []

    if not _NAMING_RE.match(skill_name):
        errors.append(
            Error(
                skill_name,
                f"directory name '{skill_name}' must follow "
                f"{{scope}}-{{domain}}-{{action}}[-{{variant}}] "
                f"(3 required parts + optional variant, "
                f"e.g. py-doc-updater or py-test-generator-unit)",
            )
        )
        return errors  # Parts cannot be checked if the structure is wrong

    # Split into at most 4 parts; the optional variant is free-form and not validated.
    parts = skill_name.split("-", 3)
    scope, domain, action = parts[0], parts[1], parts[2]

    if scope not in _APPROVED_SCOPES:
        errors.append(
            Error(
                skill_name,
                f"unknown scope '{scope}' — see README § Naming convention for approved tags",
            )
        )
    if domain not in _APPROVED_DOMAINS:
        errors.append(
            Error(
                skill_name,
                f"unknown domain '{domain}' — see README § Naming convention for approved tags",
            )
        )
    if action not in _APPROVED_ACTIONS:
        errors.append(
            Error(
                skill_name,
                f"unknown action '{action}' — see README § Naming convention for approved tags",
            )
        )

    return errors


def validate_skill_md(skill_dir: Path) -> list[Error]:
    """Validate the SKILL.md in a skill directory."""
    errors: list[Error] = []
    skill_name = skill_dir.name
    skill_md = skill_dir / "SKILL.md"

    content = skill_md.read_text(encoding="utf-8")

    # Frontmatter presence
    fm = parse_frontmatter(content)
    if fm is None:
        errors.append(Error(skill_name, "SKILL.md: missing frontmatter (---...--- block)"))
        return errors  # Cannot validate further without frontmatter

    # name field
    if "name" not in fm:
        errors.append(Error(skill_name, "SKILL.md: frontmatter missing 'name' field"))
    elif not _KEBAB_RE.match(fm["name"]):
        errors.append(Error(skill_name, f"SKILL.md: 'name' must be kebab-case, got '{fm['name']}'"))

    # description field
    if "description" not in fm:
        errors.append(Error(skill_name, "SKILL.md: frontmatter missing 'description' field"))
    else:
        desc = fm["description"]
        if len(desc) < MIN_DESCRIPTION_CHARS:
            errors.append(
                Error(
                    skill_name,
                    f"SKILL.md: 'description' is {len(desc)} chars, "
                    f"minimum is {MIN_DESCRIPTION_CHARS}",
                )
            )
        errors.extend(check_for_slop(desc, skill_name, "SKILL.md description"))
        errors.extend(check_for_placeholders(desc, skill_name, "SKILL.md description"))

    # Body length (content after frontmatter)
    body_start = content.find("---", content.find("---") + 3)
    body = content[body_start + 3 :].strip() if body_start != -1 else ""
    if len(body) < MIN_BODY_CHARS:
        errors.append(
            Error(
                skill_name,
                f"SKILL.md: body is {len(body)} chars, minimum is {MIN_BODY_CHARS}",
            )
        )

    # Placeholder text anywhere in the file
    errors.extend(check_for_placeholders(content, skill_name, "SKILL.md"))

    return errors


def validate_python_scripts(skill_dir: Path) -> list[Error]:
    """Validate all Python scripts in the skill's scripts/ directory."""
    errors: list[Error] = []
    skill_name = skill_dir.name
    scripts_dir = skill_dir / "scripts"

    if not scripts_dir.is_dir():
        return errors

    for py_file in sorted(scripts_dir.glob("*.py")):
        rel = py_file.relative_to(skill_dir.parent)

        # Syntax check
        source = py_file.read_text(encoding="utf-8")
        try:
            tree = ast.parse(source, filename=str(py_file))
        except SyntaxError as exc:
            errors.append(Error(skill_name, f"{rel}: syntax error: {exc}"))
            continue

        # Module-level docstring
        if not ast.get_docstring(tree):
            errors.append(Error(skill_name, f"{rel}: missing module-level docstring"))

    return errors


def validate_skill(skill_dir: Path) -> list[Error]:
    errors = validate_directory_name(skill_dir.name)
    errors.extend(validate_skill_md(skill_dir))
    errors.extend(validate_python_scripts(skill_dir))
    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate skill directories in the hub.")
    parser.add_argument("--root", type=Path, default=Path("."), help="Repository root.")
    args = parser.parse_args()

    root = args.root.resolve()
    skill_dirs = find_skill_dirs(root)

    if not skill_dirs:
        print("No skill directories found.")
        sys.exit(0)

    all_errors: list[Error] = []
    for skill_dir in skill_dirs:
        errors = validate_skill(skill_dir)
        all_errors.extend(errors)

    if all_errors:
        print(f"Skill validation failed ({len(all_errors)} error(s)):\n")
        for err in all_errors:
            print(err)
        sys.exit(1)

    print(f"All {len(skill_dirs)} skill(s) valid.")
    for sd in skill_dirs:
        print(f"  OK  {sd.name}")


if __name__ == "__main__":
    main()

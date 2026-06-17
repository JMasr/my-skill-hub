# Python Documentation Conventions

Reference for writing and updating Python project documentation.
Load this before Phase 3 (Update) to apply consistent quality standards.

## Docstring Style

Follow **Google style** by default unless the project already uses NumPy or
Sphinx (reST) style — match what's already there.

### Google style quick reference

```python
def fetch_user(user_id: int, *, include_deleted: bool = False) -> User:
    """Fetch a user by their database ID.

    Retrieves the user record from the primary database. Returns a hydrated
    User object with profile data loaded.

    Args:
        user_id: The unique identifier for the user.
        include_deleted: If True, also search soft-deleted records.

    Returns:
        The matching User object.

    Raises:
        UserNotFoundError: If no user matches the given ID.
        DatabaseConnectionError: If the database is unreachable.

    Example:
        >>> user = fetch_user(42)
        >>> user.name
        'Alice'
    """
```

### Key rules
- First line is a single imperative sentence (no period if it fits one line).
- Blank line between summary and extended description.
- Args section: parameter name followed by colon and description. Omit type
  annotations in docstrings when they're already in the signature.
- Returns: describe the return value, not the type.
- Include `Raises` only for exceptions the caller should handle.
- Add `Example` with a doctest when the usage isn't obvious.

## Module-level docstrings

Every `__init__.py` should have a module docstring explaining:
1. What the package/module does (one sentence).
2. Key classes or functions it exports (brief list).
3. Basic usage example if the module is a primary entry point.

```python
"""User authentication and session management.

Provides the auth pipeline used by the API layer. Key exports:

- ``authenticate(credentials)`` — validate and return a session token.
- ``AuthMiddleware`` — ASGI middleware for token verification.
- ``InvalidCredentialsError`` — raised on auth failure.

Example:
    token = authenticate(Credentials(email="a@b.com", password="s3cret"))
"""
```

## README structure

A Python project README should cover these sections in order. Not all are
required — match the project's scope.

1. **Title + badges** — project name, PyPI version, CI status, coverage.
2. **One-liner** — what it does, in one sentence.
3. **Installation** — `pip install`, extras, Python version constraints.
4. **Quick start** — minimal working example (3-10 lines of code).
5. **Features** — bullet list of capabilities.
6. **Configuration** — environment variables, config files, CLI flags.
7. **API overview** — only for libraries; link to full API docs.
8. **Development** — how to set up a dev environment, run tests.
9. **Contributing** — link to CONTRIBUTING.md or inline guidelines.
10. **License** — SPDX identifier or link.

### README quality checks
- Every code block specifies a language (`python`, `bash`, `yaml`).
- Installation instructions include the exact package name.
- Quick start example is copy-pasteable — no undefined variables or missing
  imports.
- Version-specific notes say "Added in v1.2" not "recently added".

## CHANGELOG conventions

Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

### Categories (in this order)
1. **Added** — new features.
2. **Changed** — changes in existing functionality.
3. **Deprecated** — features marked for future removal.
4. **Removed** — removed features.
5. **Fixed** — bug fixes.
6. **Security** — vulnerability patches.

### Writing good entries
- Lead with the user impact, not the implementation.
  - Good: "The `parse` function now accepts `Path` objects in addition to strings."
  - Bad: "Refactored parse function to use os.fspath internally."
- One entry per user-visible change, even if it took multiple commits.
- Reference issues/PRs: `Fixed race condition in queue processing (#247).`
- Bold breaking changes: `**BREAKING:** Removed deprecated `v1_endpoint` function.`
- Use past tense for Fixed/Removed, present for Added/Changed.

## API reference docs

When a project uses Sphinx or MkDocs with autodoc:

- Keep docstrings as the single source of truth — don't duplicate in `.md` files.
- Handwritten API docs should document *concepts* and *workflows*, not repeat
  the signature.
- Group related functions/classes by use case, not alphabetically.
- Mark internal APIs clearly with a leading underscore or an "Internal" section
  heading.

When a project has handwritten API docs (no autodoc):

- Include the full signature with type annotations.
- Show a usage example for each public function.
- Document side effects, thread safety, and reentrancy when relevant.

## Deprecation notices

When documenting deprecated APIs:

```python
def old_function():
    """Do something.

    .. deprecated:: 2.0
        Use :func:`new_function` instead. Will be removed in v3.0.
    """
    import warnings
    warnings.warn(
        "old_function is deprecated, use new_function instead",
        DeprecationWarning,
        stacklevel=2,
    )
```

In Markdown docs:
```markdown
> **Deprecated since v2.0:** `old_function()` is deprecated.
> Use [`new_function()`](#new-function) instead. Scheduled for removal in v3.0.
```

Always include: what replaces it, and when it will be removed.

## Type annotations in docs

- Don't repeat type annotations that are already in the function signature.
- In docstrings, describe *what* a parameter is, not its type.
- When a type is complex (`Union[str, Path, IO[bytes]]`), explain what each
  accepted type means for behavior:
  "path_or_stream: A filesystem path (str or Path) to read from, or an open
  binary stream."

## Cross-referencing

In Sphinx/reST:
```rst
See :func:`module.function_name` and :class:`module.ClassName`.
```

In MkDocs/Markdown:
```markdown
See [`function_name`](api.md#function-name) and [`ClassName`](api.md#classname).
```

In plain Markdown (no doc system):
Use relative links: `[Configuration](docs/configuration.md)`.

## Quality checklist

Before finishing any doc update, verify:

- [ ] No references to removed functions, classes, or CLI flags.
- [ ] Code examples run without errors on the current codebase.
- [ ] Version numbers match the actual release (not hardcoded old versions).
- [ ] Links are not broken (internal or external).
- [ ] New features have at least one code example.
- [ ] Breaking changes are prominently marked.
- [ ] The tone matches the existing documentation (formal, casual, tutorial-style).
- [ ] No "TODO", "FIXME", or placeholder text left in published docs.

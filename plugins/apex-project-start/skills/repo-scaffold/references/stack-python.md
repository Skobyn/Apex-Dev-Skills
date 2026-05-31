# Stack: Python

Modern defaults (2025–2026): **uv** (project/package/python manager) + **Ruff** (lint+format) + **pyright** or **mypy** (types) + **pytest** + **src layout** + a single **`pyproject.toml`**. No `requirements.txt`; commit `uv.lock`.

## Tooling decisions

| Concern | Default | When to deviate |
|---|---|---|
| Project manager | **uv** (`uv init`/`uv add`/`uv sync`) | — (replaces pip/poetry/pyenv/virtualenv/pipx) |
| Lint + format | **Ruff** | — (replaces black/isort/flake8) |
| Type checker | **pyright** (fast, strict) | **mypy** for widest ecosystem maturity |
| Test | **pytest** + `pytest-cov` | — |
| Layout | **src layout** | flat only for throwaway scripts |
| Python pin | `.python-version` (uv-managed) + `requires-python` | — |

## Files to generate

### `pyproject.toml`
```toml
[project]
name = "<project-name>"
version = "0.1.0"
description = "<purpose>"
readme = "README.md"
requires-python = ">=3.12"
license = { text = "<SPDX>" }
authors = [{ name = "skobyn", email = "skobyn@gmail.com" }]
dependencies = []

[dependency-groups]
dev = [
  "pytest>=8.3",
  "pytest-cov>=6.0",
  "ruff>=0.8",
  "pyright>=1.1.390",
  "vulture>=2.14",   # periodic dead-code sweep (not a CI gate)
  "deptry>=0.21",    # periodic unused-dependency audit
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.ruff]
line-length = 100
src = ["src", "tests"]

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM", "RUF"]

[tool.pytest.ini_options]
addopts = "--cov=<package_name> --cov-report=term-missing --cov-fail-under=80"
testpaths = ["tests"]
pythonpath = ["src"]
filterwarnings = ["error"]   # warnings-as-errors: a runtime warning fails the test

[tool.pyright]
include = ["src", "tests"]
typeCheckingMode = "strict"

[tool.vulture]
paths = ["src", "vulture_whitelist.py"]
min_confidence = 80
sort_by_size = true
```
Dead-code sweep is **periodic, not a CI gate** (vulture is heuristic). See
[maintenance-and-hygiene.md](maintenance-and-hygiene.md) for the sweep script, the
`vulture_whitelist.py` workflow, and the last-run tracking that reminds you after 3 days.
Replace `<package_name>` with the import package (snake_case of project name).

### `.python-version`
```
3.12
```

### Source + test (src layout)
`src/<package_name>/__init__.py`:
```python
def greet(name: str) -> str:
    """Return a friendly greeting."""
    return f"Hello, {name}!"
```
`tests/test_greet.py`:
```python
from <package_name> import greet


def test_greet() -> None:
    assert greet("world") == "Hello, world!"
```

### `mise.toml` (optional; uv can manage python alone)
```toml
[tools]
python = "3.12"
uv = "latest"
```

## Extend `.gitignore`
```
__pycache__/
*.py[cod]
.venv/
.pytest_cache/
.ruff_cache/
.coverage
htmlcov/
dist/
*.egg-info/
```

## Finalize commands
```bash
uv sync
uv run pytest
uv run ruff check .
uv run pyright
```
Periodic (not at init, not in CI): `scripts/dead-code-sweep.sh` → `uv run vulture src/ --min-confidence 80 --sort-by-size`. Also create an empty `vulture_whitelist.py` at init so the command runs clean.

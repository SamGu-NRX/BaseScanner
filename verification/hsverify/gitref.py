"""Read-only access to other branches through throwaway worktrees under /tmp.

Verification never checks out another thread's branch in its own worktree and never
pushes to one. A detached worktree at the exact commit keeps the evidence tied to a SHA.
"""

from __future__ import annotations

import contextlib
import shutil
import subprocess
from collections.abc import Iterator
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TMP_ROOT = Path("/tmp")


def git(*args: str, cwd: Path = REPO) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def fetch() -> None:
    git("fetch", "--quiet", "origin")


def resolve(ref: str) -> str:
    """Full SHA of a ref. Raises CalledProcessError with git's message if it does not exist."""
    return git("rev-parse", "--verify", f"{ref}^{{commit}}")


def ref_exists(ref: str) -> bool:
    try:
        resolve(ref)
    except subprocess.CalledProcessError:
        return False
    return True


def show(ref: str, path: str) -> str | None:
    """File contents at a ref, or None when the file does not exist there."""
    try:
        return git("show", f"{ref}:{path}")
    except subprocess.CalledProcessError:
        return None


@contextlib.contextmanager
def detached_worktree(sha: str, keep: bool = False) -> Iterator[Path]:
    """A detached worktree of `sha` at /tmp/hs-verify-<sha12>, removed afterwards unless `keep`.

    An existing worktree at that path is reused, since it holds the same commit.
    """
    path = TMP_ROOT / f"hs-verify-{sha[:12]}"
    if not (path / ".git").exists():
        if path.exists():
            shutil.rmtree(path)
        git("worktree", "add", "--detach", "--force", str(path), sha)
        # The landing page submodule is not needed for any check here.
    try:
        yield path
    finally:
        if not keep:
            git("worktree", "remove", "--force", str(path))

"""
Module: setup_repo.py
Description: Idempotent, guardrail-compliant repository setup automation.
             Initializes Git, sets identity, renames branch to main, stages
             files, commits, creates the GitHub repository via gh, and pushes.
             Uses subprocess.Popen exclusively (no subprocess.run, no sed,
             no set -e); exit codes are 0 (success) or 2 (handled failure).
Citations:
- gh repo create: https://cli.github.com/manual/gh_repo_create
- subprocess.Popen: https://docs.python.org/3/library/subprocess.html#subprocess.Popen
"""

import logging
import subprocess
import sys
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

REPO_OWNER = "swipswaps"
REPO_NAME = "production-local-rag"
BRANCH = "main"
COMMIT_MSG = "chore: refresh repo state"


def run(cmd: list[str]) -> tuple[int, str, str]:
    """
    Execute a command via subprocess.Popen and capture stdout/stderr.

    Args:
        cmd: Full argv list.

    Returns:
        (returncode, stdout, stderr) triple. 2 on FileNotFoundError.
    """
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        out, err = proc.communicate()
        return proc.returncode, out, err
    except FileNotFoundError as exc:
        return 2, "", f"command not found: {cmd[0]}: {exc}"


def main() -> int:
    """
    Orchestrate git init / add / commit / gh create / push.

    Returns:
        0 on success, 2 on handled failure.
    """
    repo_dir = Path(__file__).resolve().parent
    logger.info("Working directory: %s", repo_dir)

    if (repo_dir / ".git").exists():
        logger.info("Git repository already initialized.")
    else:
        code, _out, err = run(["git", "init"])
        if code != 0:
            logger.error("git init failed: %s", err.strip())
            return 2
        logger.info("Initialized empty Git repository.")

    run(["git", "config", "user.name", REPO_OWNER])
    run(["git", "config", "user.email", f"{REPO_OWNER}@users.noreply.github.com"])
    run(["git", "branch", "-M", BRANCH])

    code, _out, err = run(["git", "add", "."])
    if code != 0:
        logger.error("git add failed: %s", err.strip())
        return 2

    code, out, err = run(["git", "commit", "-m", COMMIT_MSG])
    if code != 0:
        combined = (out + err).lower()
        if "nothing to commit" not in combined and "no changes added" not in combined:
            logger.warning("git commit notice: %s", (out + err).strip())

    code, out, err = run([
        "gh", "repo", "create", f"{REPO_OWNER}/{REPO_NAME}",
        "--public", "--source=.", "--remote=origin", "--push",
    ])
    if code != 0:
        combined = (out + err).lower()
        if "already exists" in combined or "already configured" in combined:
            logger.info("Repo exists on GitHub; ensuring remote and pushing.")
            run(["git", "remote", "set-url", "origin",
                 f"https://github.com/{REPO_OWNER}/{REPO_NAME}.git"])
            code, _out, err = run(["git", "push", "-u", "origin", BRANCH])
            if code != 0:
                logger.error("git push failed: %s", err.strip())
                return 2
        else:
            logger.error("gh repo create failed: %s", err.strip())
            return 2

    logger.info("Repository sync complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

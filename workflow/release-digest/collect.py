#!/usr/bin/env python3
"""Collect commits from a git range and emit them as structured JSON.

Reads nothing but `git log`. No network, no external services, stdlib only.
Conventional-commit prefixes (feat:, fix(scope):, etc.) are parsed when
present, but plain commit subjects work fine too.

Usage:
    # By revision range (anything `git log` accepts)
    python3 collect.py --range v1.2.0..HEAD > commits.json
    python3 collect.py --range abc123..def456 > commits.json

    # By date window (inclusive of the whole --until day)
    python3 collect.py --from 2026-05-26 --until 2026-06-02 > commits.json

    # Defaults: since the most recent tag, or last 30 days if no tags
    python3 collect.py > commits.json

Each emitted element:
{
  "hash": "abc1234",
  "subject": "fix(api): handle empty payload (#123)",
  "body": "Longer description...",
  "author": "Jane Doe",
  "date": "2026-05-27",
  "type": "fix",            # conventional-commit type, or "" if none
  "scope": "api",           # conventional-commit scope, or "" if none
  "breaking": false,        # "!" marker or "BREAKING CHANGE:" in body
  "description": "handle empty payload",  # subject minus type/scope/PR ref
  "pr_number": "123",       # from a trailing "(#N)", or "" if none
  "headline": ""            # left blank for the skill to fill with prose
}
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys

# Field/record separators unlikely to appear in commit text.
_FS = "\x1f"  # between fields
_RS = "\x1e"  # between records

_CONVENTIONAL = re.compile(
    r"^(?P<type>\w+)"
    r"(?:\((?P<scope>[^)]*)\))?"
    r"(?P<bang>!)?"
    r":\s*(?P<desc>.*)$"
)
_PR_REF = re.compile(r"\s*\(#(\d+)\)\s*$")


def _run(args: list[str]) -> str:
    return subprocess.run(
        args, check=True, capture_output=True, text=True
    ).stdout


def _require_git_repo() -> None:
    """Fail early with a clear message if cwd isn't inside a git work tree.

    collect.py operates on the repo containing the current working directory
    (it never names a repo). Without this guard, running it elsewhere would
    surface a raw git error from deep in the call stack.
    """
    try:
        inside = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print(
            "error: `git` was not found on PATH — install git to use this skill.",
            file=sys.stderr,
        )
        raise SystemExit(2)
    if inside.returncode != 0 or inside.stdout.strip() != "true":
        print(
            "error: not inside a git repository.\n"
            "Run release-digest from within the repository whose commits you "
            "want to turn into release notes (collect.py reads the repo "
            "containing the current working directory).",
            file=sys.stderr,
        )
        raise SystemExit(2)


def _default_range() -> str:
    """Most recent tag..HEAD, or empty (meaning: use date fallback)."""
    try:
        last_tag = _run(
            ["git", "describe", "--tags", "--abbrev=0"]
        ).strip()
    except subprocess.CalledProcessError:
        return ""
    return f"{last_tag}..HEAD" if last_tag else ""


def _parse_subject(subject: str) -> dict:
    pr_number = ""
    m = _PR_REF.search(subject)
    if m:
        pr_number = m.group(1)
        subject_clean = _PR_REF.sub("", subject)
    else:
        subject_clean = subject

    type_ = scope = ""
    breaking = False
    description = subject_clean

    cm = _CONVENTIONAL.match(subject_clean)
    if cm:
        type_ = cm.group("type").lower()
        scope = cm.group("scope") or ""
        breaking = bool(cm.group("bang"))
        description = cm.group("desc")

    return {
        "type": type_,
        "scope": scope,
        "breaking": breaking,
        "description": description,
        "pr_number": pr_number,
    }


def collect(log_args: list[str]) -> list[dict]:
    fmt = _FS.join(["%h", "%s", "%an", "%ad", "%b"]) + _RS
    raw = _run(
        ["git", "log", f"--pretty=format:{fmt}", "--date=short", *log_args]
    )

    commits: list[dict] = []
    for record in raw.split(_RS):
        record = record.strip("\n")
        if not record:
            continue
        parts = record.split(_FS)
        if len(parts) < 5:
            continue
        short_hash, subject, author, date, body = parts[:5]

        parsed = _parse_subject(subject.strip())
        if "BREAKING CHANGE" in body:
            parsed["breaking"] = True

        commits.append(
            {
                "hash": short_hash,
                "subject": subject.strip(),
                "body": body.strip(),
                "author": author.strip(),
                "date": date.strip(),
                "headline": "",
                **parsed,
            }
        )
    return commits


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--range", help="git revision range, e.g. v1.0.0..HEAD")
    p.add_argument("--from", dest="from_", help="start date YYYY-MM-DD")
    p.add_argument("--until", help="end date YYYY-MM-DD (inclusive)")
    p.add_argument(
        "--no-merges", action="store_true", help="exclude merge commits"
    )
    args = p.parse_args(argv)

    _require_git_repo()

    log_args: list[str] = []
    if args.no_merges:
        log_args.append("--no-merges")

    if args.from_ or args.until:
        if args.from_:
            log_args.append(f"--since={args.from_}")
        if args.until:
            # Make --until inclusive of the whole calendar day.
            until = dt.date.fromisoformat(args.until) + dt.timedelta(days=1)
            log_args.append(f"--until={until.isoformat()}")
    elif args.range:
        log_args.append(args.range)
    else:
        rng = _default_range()
        if rng:
            log_args.append(rng)
        else:
            log_args.append("--since=30 days ago")
            print(
                "no tags found; defaulting to commits from the last 30 days",
                file=sys.stderr,
            )

    json.dump(collect(log_args), sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

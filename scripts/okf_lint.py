#!/usr/bin/env python3
"""OKF v0.2 conformance check for the knowledge/ bundle. No dependencies.

Errors (exit 1):
  - a concept without frontmatter, or without a non-empty `type`
  - frontmatter in a non-root index.md, or root index.md keys other than okf_version
  - log.md date headings that aren't YYYY-MM-DD or aren't newest first
Warnings:
  - links to .md files that don't exist (OKF allows them; they may be unwritten knowledge)
  - concepts or folders missing from their parent index.md
"""
import re
import sys
from pathlib import Path

BUNDLE = Path(__file__).resolve().parent.parent / "knowledge"
LINK = re.compile(r"\]\(([^)\s]+?\.md)(?:#[^)]*)?\)")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

errors, warnings = [], []


def rel(path):
    return path.relative_to(BUNDLE.parent)


def frontmatter(text):
    """Return the frontmatter lines, or None when the file has no frontmatter block."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None
    for i, line in enumerate(lines[1:], 1):
        if line.strip() == "---":
            return lines[1:i]
    return None


def top_level_keys(lines):
    return [m.group(1) for line in lines if (m := re.match(r"^([A-Za-z_][\w-]*):", line))]


def check_concept(path, text):
    fm = frontmatter(text)
    if fm is None:
        errors.append(f"{rel(path)}: no YAML frontmatter")
        return
    types = [line.split(":", 1)[1].strip().strip("'\"") for line in fm if line.startswith("type:")]
    if not types or not types[0]:
        errors.append(f"{rel(path)}: frontmatter has no non-empty `type`")


def check_index(path, text):
    fm = frontmatter(text)
    if fm is None:
        return
    if path.parent != BUNDLE:
        errors.append(f"{rel(path)}: index.md may only carry frontmatter at the bundle root")
    elif extra := [k for k in top_level_keys(fm) if k != "okf_version"]:
        errors.append(f"{rel(path)}: root index.md frontmatter allows only okf_version, found {extra}")


def check_log(path, text):
    dates = [m.group(1).strip() for m in re.finditer(r"^## (.+)$", text, re.M)]
    for d in dates:
        if not DATE.match(d):
            errors.append(f"{rel(path)}: log heading '{d}' isn't YYYY-MM-DD")
    valid = [d for d in dates if DATE.match(d)]
    if valid != sorted(valid, reverse=True):
        errors.append(f"{rel(path)}: log dates aren't newest first")


def check_links(path, text):
    for target in LINK.findall(text):
        if "://" in target:
            continue
        resolved = BUNDLE / target[1:] if target.startswith("/") else path.parent / target
        if not resolved.exists():
            warnings.append(f"{rel(path)}: link to missing {target}")


def check_listed(path):
    index = path.parent / "index.md"
    if path.name == "index.md":  # a folder: its parent's index should list it
        if path.parent == BUNDLE:
            return
        index, name = path.parent.parent / "index.md", path.parent.name + "/"
    else:
        name = path.name
    if not index.exists() or name not in index.read_text(encoding="utf-8"):
        warnings.append(f"{rel(path)}: not listed in {rel(index)}")


def main():
    if not BUNDLE.is_dir():
        sys.exit(f"no bundle at {BUNDLE}")
    concepts = 0
    for path in sorted(BUNDLE.rglob("*.md")):
        text = path.read_text(encoding="utf-8")
        if path.name == "index.md":
            check_index(path, text)
        elif path.name == "log.md":
            check_log(path, text)
        else:
            concepts += 1
            check_concept(path, text)
        check_links(path, text)
        if path.name != "log.md":
            check_listed(path)
    for w in warnings:
        print(f"warning: {w}")
    for e in errors:
        print(f"error: {e}")
    print(f"OKF: {concepts} concepts, {len(errors)} errors, {len(warnings)} warnings")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()

"""Apply exact patches, requiring context-free replacements to be unambiguous."""
from pathlib import Path
import subprocess
import sys


def apply_patch(work_dir, patch):
    lines = patch.read_text().splitlines()
    source = None
    position = 0
    while position < len(lines):
        line = lines[position]
        if line == "--- /dev/null":
            source = None
        elif line.startswith("--- a/"):
            source = work_dir / line.removeprefix("--- a/")
        if not line.startswith("@@ "):
            position += 1
            continue
        position += 1
        hunk = []
        while position < len(lines) and not lines[position].startswith(("@@ ", "diff --git ")):
            hunk.append(lines[position])
            position += 1
        if any(line.startswith(" ") for line in hunk):
            continue
        # New files have no previous content to disambiguate. Git validates
        # that the destination does not already exist.
        if source is None:
            continue
        removed = [line[1:] for line in hunk if line.startswith("-")]
        if not removed:
            raise ValueError("context-free hunks must replace existing lines")
        source_lines = source.read_text().splitlines()
        matches = sum(
            source_lines[index:index + len(removed)] == removed
            for index in range(len(source_lines) - len(removed) + 1)
        )
        if matches != 1:
            raise ValueError(f"{patch.name}: context-free replacement has {matches} matches in {source.relative_to(work_dir)}; expected one")
    subprocess.run(
        ["git", "-C", str(work_dir), "apply", "--unidiff-zero", "--whitespace=nowarn", str(patch)],
        check=True,
    )


if __name__ == "__main__":
    try:
        apply_patch(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))

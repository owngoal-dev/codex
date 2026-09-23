#!/usr/bin/env bash
#
# Fetch upstream at the pinned ref into <work-dir> and apply patches/ on top.
#
# Idempotent: a stamp records the ref plus the digest of every patch, so a
# repeat call with nothing changed leaves the tree alone. When something has
# changed the checkout is reset hard and repatched.

set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 <work-dir>" >&2
    exit 64
fi

work_dir="$1"
repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
patch_dir="$repository_root/patches"

# shellcheck source=../configuration/upstream.env
source "$repository_root/configuration/upstream.env"

: "${UPSTREAM_REPO:?configuration/upstream.env must set UPSTREAM_REPO}"
: "${UPSTREAM_REF:?configuration/upstream.env must set UPSTREAM_REF}"

[[ -d "$patch_dir" ]] || { echo "error: missing patches directory: $patch_dir" >&2; exit 66; }

shopt -s nullglob
patches=("$patch_dir"/*.patch)
shopt -u nullglob
((${#patches[@]} > 0)) || { echo "error: patches/ holds no .patch files" >&2; exit 66; }

version_file="$repository_root/configuration/version.txt"
package_version="$(tr -d '[:space:]' <"$version_file")"
cargo_version="${package_version%%-*}"
[[ "$cargo_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: cargo version derived from '$package_version' is not X.Y.Z" >&2
    exit 65
}

stamp_input="$UPSTREAM_REPO@$UPSTREAM_REF"$'\n'
stamp_input+="cargo-version $cargo_version"$'\n'
stamp_input+="$(shasum -a 256 "$repository_root/scripts/apply-patch.py" | cut -d ' ' -f 1)"$'\n'
for patch in "${patches[@]}"; do
    stamp_input+="$(shasum -a 256 "$patch" | cut -d ' ' -f 1)  $(basename "$patch")"$'\n'
done
stamp="$(printf '%s' "$stamp_input" | shasum -a 256 | cut -d ' ' -f 1)"
stamp_file="$work_dir/.owngoal-source-stamp"

if [[ -f "$stamp_file" && "$(cat "$stamp_file")" == "$stamp" ]]; then
    echo "source is already prepared at $UPSTREAM_REF with ${#patches[@]} patch(es)"
    exit 0
fi

mkdir -p "$work_dir"
if [[ ! -d "$work_dir/.git" ]]; then
    git -C "$work_dir" init --quiet
    git -C "$work_dir" remote add origin "$UPSTREAM_REPO"
fi

git -C "$work_dir" remote set-url origin "$UPSTREAM_REPO"
rm -f "$stamp_file"

echo "fetching $UPSTREAM_REPO at $UPSTREAM_REF"
git -C "$work_dir" fetch --quiet --depth 1 --force origin "$UPSTREAM_REF"
git -C "$work_dir" checkout --quiet --force --detach FETCH_HEAD
git -C "$work_dir" reset --quiet --hard FETCH_HEAD
git -C "$work_dir" clean -qfdx

resolved_ref="$(git -C "$work_dir" rev-parse HEAD)"
echo "checked out $resolved_ref"

for patch in "${patches[@]}"; do
    echo "applying $(basename "$patch")"
    # Dependency-only hunks omit neighboring crates so additions and unrelated
    # version bumps cannot break them. Exact removed lines must still match.
    if ! python3 "$repository_root/scripts/apply-patch.py" "$work_dir" "$patch"; then
        echo "error: $(basename "$patch") does not apply to $resolved_ref" >&2
        echo "       upstream moved; rebase the patch or repin UPSTREAM_REF" >&2
        exit 65
    fi
done

# A patch can apply cleanly and still break a manifest, e.g. by adding a
# target table that upstream has since added too. Cargo would only say so at
# build time, after Follow upstream has already tagged the release.
python3 - "$work_dir" "${patches[@]}" <<'PY'
from pathlib import Path
import re
import sys
import tomllib
work_dir = Path(sys.argv[1])
manifests = {
    name
    for patch in sys.argv[2:]
    for name in re.findall(r"^\+\+\+ b/(\S*\.toml)$", Path(patch).read_text(), re.M)
}
for name in sorted(manifests):
    try:
        tomllib.loads((work_dir / name).read_text())
    except tomllib.TOMLDecodeError as error:
        raise SystemExit(f"error: patched {name} is not valid TOML: {error}")
PY

# Older upstream trees carry a 0.0.0 placeholder that official releases
# rewrite at tag time; newer ones commit the real version. Either way
# `codex --version` must match the package, and any other value means the
# pin and configuration/version.txt disagree.
: "${CARGO_DIR:?configuration/upstream.env must set CARGO_DIR}"
workspace_toml="$work_dir/$CARGO_DIR/Cargo.toml"
[[ -f "$workspace_toml" ]] || {
    echo "error: missing workspace Cargo.toml at $workspace_toml" >&2
    exit 66
}
python3 - "$workspace_toml" "$cargo_version" <<'PY'
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
match = re.search(r'^\[workspace\.package\]\n(?:[^\[].*\n)*?version = "([^"]+)"', text, re.M)
if not match:
    raise SystemExit(f"{path} has no [workspace.package] version to rewrite")
found = match.group(1)
if found not in ("0.0.0", version):
    raise SystemExit(f"{path} is version {found}, but configuration pins {version}")
start, end = match.span(1)
path.write_text(text[:start] + version + text[end:])
PY
echo "set workspace version to $cargo_version"

printf '%s\n' "$stamp" >"$stamp_file"
echo "prepared $UPSTREAM_REF with ${#patches[@]} patch(es)"

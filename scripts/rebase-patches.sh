#!/usr/bin/env bash
#
# Rebase patches/ onto a new upstream commit when `make source` stops applying.
#
#   scripts/rebase-patches.sh <sha>          # check out <sha> into build/rebase,
#                                            # apply patches/ with fuzz, list rejects
#   scripts/rebase-patches.sh <sha> --write  # rewrite patches/ from build/rebase,
#                                            # then prove they apply cleanly
#
# Loop: run once; fix every *.rej by hand inside build/rebase (delete the .rej
# when done); run again with --write. Then move the pin (scripts/follow-upstream.sh
# or `make bump-upstream REF=<sha>` + scripts/apply-version.sh), `make check`,
# `make debs`.
#
# The patches carry no `index` lines, so git cannot three-way merge them; GNU
# patch with fuzz gets everything except real conflicts, which are usually
# reflowed comments around unchanged code.

set -Eeuo pipefail

ref="${1:-}"
mode="${2:-apply}"
[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || {
    echo "usage: $0 <full-sha> [--write]" >&2
    exit 64
}
case "$mode" in
apply | --write) ;;
*)
    echo "usage: $0 <full-sha> [--write]" >&2
    exit 64
    ;;
esac

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../configuration/upstream.env
source "$repository_root/configuration/upstream.env"
: "${UPSTREAM_REPO:?}"

work_dir="$repository_root/build/rebase"
patches=("$repository_root"/patches/*.patch)
[[ -f "${patches[0]}" ]] || { echo "no patches/ to rebase" >&2; exit 65; }

if [[ "$mode" == "apply" ]]; then
    if [[ ! -d "$work_dir/.git" ]]; then
        mkdir -p "$work_dir"
        git -C "$work_dir" init --quiet
        git -C "$work_dir" remote add origin "$UPSTREAM_REPO"
    fi
    git -C "$work_dir" remote set-url origin "$UPSTREAM_REPO"
    git -C "$work_dir" cat-file -e "$ref^{commit}" 2>/dev/null ||
        git -C "$work_dir" fetch --quiet --depth 1 --force origin "$ref"
    git -C "$work_dir" checkout --quiet --detach "$ref"
    git -C "$work_dir" reset --quiet --hard "$ref"
    git -C "$work_dir" clean -qfdx
    echo "checked out $ref into build/rebase"

    failed=0
    for patch_file in "${patches[@]}"; do
        name="$(basename "$patch_file")"
        if output="$(patch -d "$work_dir" -p1 -F3 --no-backup-if-mismatch -i "$patch_file" 2>&1)"; then
            if grep -q 'offset\|fuzz' <<<"$output"; then
                echo "$name: applied with offsets"
            else
                echo "$name: clean"
            fi
        else
            failed=1
            echo "$name: REJECTS"
            grep -i 'hunk\|saving rejects' <<<"$output" | sed 's/^/    /'
        fi
    done

    if (( failed )); then
        echo
        echo "fix these by hand in build/rebase, delete the .rej files, then rerun with --write:"
        find "$work_dir" -name '*.rej' -not -path '*/.git/*' | sed "s|^$work_dir/|    |"
        exit 65
    fi
    echo
    echo "every patch applied; review build/rebase, then rerun with --write"
    exit 0
fi

# --write
[[ "$(git -C "$work_dir" rev-parse HEAD 2>/dev/null)" == "$ref" ]] || {
    echo "error: build/rebase is not at $ref; run without --write first" >&2
    exit 65
}
if find "$work_dir" -name '*.rej' -not -path '*/.git/*' | grep -q .; then
    echo "error: unresolved *.rej files remain in build/rebase" >&2
    exit 65
fi

git -C "$work_dir" add -A
for patch_file in "${patches[@]}"; do
    name="$(basename "$patch_file")"
    mapfile -t files < <(sed -n 's|^diff --git a/\(.*\) b/.*|\1|p' "$patch_file")
    git -C "$work_dir" diff --cached -- "${files[@]}" | grep -v '^index ' >"$patch_file" || true
    if [[ ! -s "$patch_file" ]]; then
        echo "error: $name came out empty; its changes are gone from build/rebase" >&2
        exit 65
    fi
    echo "rewrote $name ($(grep -c '^diff --git' "$patch_file") file(s))"
done

git -C "$work_dir" reset --quiet --hard "$ref"
git -C "$work_dir" clean -qfdx
for patch_file in "${patches[@]}"; do
    python3 "$repository_root/scripts/apply-patch.py" "$work_dir" "$patch_file" || {
        echo "error: rewritten $(basename "$patch_file") does not apply cleanly" >&2
        exit 65
    }
done
echo "patches/ rebased onto $ref and verified; now move the pin and run make check"

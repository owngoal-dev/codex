# codex — Agent Notes

[OpenAI Codex](https://github.com/openai/codex) — the terminal coding
agent — built for jailbroken iOS 15+ and installed as `codex`, for both
**roothide** and **rootless** bootstraps.

This repository holds **no application source**. It fetches openai/codex at a
pinned commit, applies `patches/`, cross-compiles for `aarch64-apple-ios`, and
packages. Everything runs through `scripts/`, so CI and a local checkout
execute the same code.

## Hard rules

- **Not a fork.** Never vendor openai/codex source here. Every change to it is a
  patch in `patches/`, applied by `scripts/prepare-source.sh` to a fresh
  checkout of `UPSTREAM_REF`. Keep patches small and single-purpose.
- **`UPSTREAM_REF` is a full commit sha**, not a branch. Bump with
  `make bump-upstream REF=…`.
- **One arm64 binary backs both packages.** arm64 runs on every arm64e device
  and the reverse is not true. The two `.deb` architectures name a *bootstrap
  layout*, not a CPU: `iphoneos-arm64` is rootless, `iphoneos-arm64e` is
  roothide. Never build an arm64e slice for the "arm64e" package. Aggregate
  release targets must build that payload once, package it twice, and checksum
  only the two exact current-version outputs; device installation must select
  the same exact version so stale artifacts cannot leak into either path.
- **Never hardcode a bootstrap path in patched source.** Probe for the file and
  take the first that exists. Prefix substitution belongs in *packaging*
  (`@PREFIX@`), not in Rust.
- **Versions live in `configuration/version.txt` only.** `X.Y.Z` tracks
  upstream's crate version; `X.Y.Z-N` is a packaging-only respin.
- **Current payload uses physical paths.** Re-evaluate official vroot for a
  RootHide port, but change its launcher and all path consumers together. See below.
- **`CLAUDE.md` is a symlink to `AGENTS.md`**, never a file of its own. One
  set of notes, two names; `make check` enforces it.
- **Review for sensitive information before anything is uploaded or
  published.** This is a reading job, not a regex. Before a push, a tag or
  a release, have an agent (a subagent is fine) read the diff, the staged
  package tree and `strings` of the built binary for credentials, private
  keys, home or scratch paths, device identifiers and addresses. Nothing
  goes out until that read comes back clean. There is deliberately no
  script for this.
- **Published packages come from the Release workflow only.** Local
  `make debs` must keep working, to prove a build and to `make install` on a
  device, but a `.deb` built on a laptop is never uploaded or attached to a
  release: push the tag and let CI build, sign, review and publish.
- **Jitless V8 still needs its iOS address-space entitlement.** Sandbox-enabled
  V8 reserves a large address cage on iOS, so sign the CLI and Code Mode host
  with `com.apple.developer.kernel.extended-virtual-addressing`; do not add JIT
  or unsigned-executable-memory entitlements to solve an address-space failure.

## Current RootHide filesystem boundary

RootHide's one-line summary is `roothide = rootful + libvroot`.

**libvroot** is a compile-time shim for C/C++ bootstrap programs. When Procursus
builds git, bash, ssh, it rewrites ~200 path APIs (`open`, `stat`, `execve`,
`posix_spawn`, …) so that `/bin/sh` and `/usr/bin/git` mean "those paths inside
the randomized jbroot", and the real iOS root is reached at `/rootfs/...`.
That is why a C program compiled into the bootstrap can keep writing `/bin/sh`
and still work on roothide, and why git's hardcoded `/bin/sh` for credential
helpers does **not** need a `/var/jb` patch on roothide.

Rootless has no such shim. `/bin/sh` is simply absent (`/var/jb/bin/sh` → dash).
That is the Procursus git `SHELL_PATH=$(MEMO_PREFIX).../bin/sh` patch.

This binary is **Rust**. rustc talks to libSystem directly. It currently is not built
with libvroot. Rust is not itself a reason to reject import rewriting (fish and
coreutils use it); adopting it here requires checking all dependencies and replacing
the physical-path launcher contract together. Consequences:

- A vroot parent shell may export `SHELL=/bin/zsh`. That path is true *inside*
  the parent, and a lie to this process: `is_executable("/bin/zsh")` looks at
  the real rootfs and fails on both bootstraps.
- Runtime lookup first derives RootHide's randomized bootstrap from the
  executable directory's official `.jbroot` link, then probes `/var/jb/bin`
  and `/var/jb/usr/bin` for rootless. Unprefixed `/bin` stays in the list for
  rootful and for a future vroot-linked world we are not in.
- **Packaging** is still two layouts. roothide dpkg unpacks an unprefixed tree
  into the jbroot it picked this boot; rootless dpkg unpacks under `/var/jb`.
  The architecture field (`iphoneos-arm64e` vs `iphoneos-arm64`) names that
  layout. Do not assume RootHide exposes `/var/jb`; ask
  `dpkg --print-architecture` when the installed layout matters.

Do not add `/var/jb` to patched source as a universal jailbreak prefix. It is
one rootless candidate in a probe list; RootHide discovery must use the
per-Mach-O-directory `.jbroot` contract rather than guessing its random path.

## Layout

```
configuration/upstream.env   pinned ref, cargo package/bin, iOS floor, rustc
configuration/version.txt    package version
patches/NNNN-*.patch         applied in sorted order to a pristine checkout
packaging/DEBIAN/control     control template (@PLACEHOLDER@ substituted)
packaging/codex.entitlements  what the signed binary carries, and why
packaging/codex.launcher.c    Mach-O /usr/bin/codex → the real binary in libexec
scripts/prepare-source.sh    fetch + patch (idempotent, stamped)
scripts/rebase-patches.sh    re-target patches/ at a new upstream sha
scripts/prepare-rusty-v8.sh  fetch matching full recursive V8 source
scripts/build-ios.sh         build CLI + Code Mode host, verify both Mach-Os
scripts/package-deb.sh       stage + ldid + dpkg-deb + verify
scripts/install-device.sh    install over SSH and smoke-test (dev only)
build/                       everything generated; not source
```

## Build & verify

- `make check` — script syntax, config sanity, patch set, packaging inputs
- `make source` — fetch + patch; fails loudly if a patch no longer applies
- `make rebase-patches REF=<sha>` — when `make source` or `Follow upstream`
  fails on a patch: fuzz-applies `patches/` onto `<sha>` in `build/rebase` and
  lists the `*.rej`. Fix those by hand in `build/rebase` (usually reflowed
  comments), delete the `.rej`, rerun with `WRITE=1` to rewrite and re-verify
  `patches/`, then move the pin (`scripts/follow-upstream.sh`) and `make check`.
  Upstream trees newer than 0.152 commit the real workspace version instead of
  the `0.0.0` placeholder; `prepare-source.sh` accepts either and refuses any
  other value as a pin/version mismatch. Dependency-only replacements may use
  zero-context hunks to avoid coupling to neighboring crate versions; preparation
  uses `scripts/apply-patch.py` to require one exact match before
  `git apply --unidiff-zero`. `make check` verifies relocation and rejects
  incompatible or ambiguous dependency changes.
- `make build` — cross-compile and verify the Mach-O is iOS
- `make debs` — both packages plus `SHA256SUMS`; what CI releases. On the
  macOS runner this takes 2 to 4 hours because V8 is built from source; the
  Release job timeout is 360 minutes, GitHub's ceiling. A run that shows
  `cancelled` at exactly the timeout was killed, not broken.
- `make install` — install on an attached device and run `--version`.
  Over USB: `iproxy 4422:2222 &`

Test by installing, never by copying a binary onto `/var/mobile`. A copied
binary runs with its entitlements ignored (trustcache never saw it).

## The owngoal-packages contract

Same as kk: a non-draft, non-prerelease tag `vX.Y.Z`; assets whose names end
in `iphoneos-arm64.deb` / `iphoneos-arm64e.deb`; a `SHA256SUMS` of bare names.

`Follow upstream` runs every day at 00:00 UTC: pin to the newest stable
`openai/codex` `rust-vX.Y.Z` release, `make source` to prove `patches/` still
apply, then commit and tag `vX.Y.Z` as `bot <bot@owngoal.dev>` and dispatch
`Release` on that tag (`gh workflow run release.yml --ref vX.Y.Z`): a tag
pushed with the workflow's own token never fires a push-triggered workflow,
and `workflow_dispatch` is the documented exception. A packaging respin
`X.Y.Z-N` already tracks upstream `X.Y.Z`, so the job advances on a new
stable version rather than a different same-version SHA. owngoal-packages
fetches the release at 04:00 UTC.

## RootHide signing and launcher checks

RootHide's official Developer README requires both
`com.apple.private.security.storage.AppBundles` and
`com.apple.private.security.storage.AppDataContainers`, in addition to the
platform and no-sandbox entitlements. Keep these in the executable signature
and verify the extracted signature after packaging; a correct package layout
alone does not establish access to RootHide's app-container installation path.
Source: https://github.com/roothide/Developer/blob/main/README.md

For payloads that do not use vroot, the Mach-O launcher asks RootHide's
`/usr/lib/libroot.dylib` for the physical bootstrap root, then exports physical
PATH, SHELL and default CA/browser paths. The rootless build compiles in
`/var/jb` and does not load libroot. Preserve explicit CA/browser settings and
already physical or custom SHELL paths. `execv` is intentional in this tiny,
single-threaded launcher: replacing it with a shell script breaks direct
execution from fish because the kernel cannot resolve RootHide's `/bin/sh`
shebang. Both launcher and payload are separately signed. Test the installed
package from sh, zsh and fish on a RootHide device.
Do not add vroot to a payload while retaining a launcher that exports physical
paths: the filesystem view must remain consistent across the boundary.

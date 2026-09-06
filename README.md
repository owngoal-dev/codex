# codex

[OpenAI Codex](https://github.com/openai/codex) — the terminal coding agent —
built for jailbroken iOS and installed as `codex`. One arm64 build, packaged
for both **roothide** and **rootless** bootstraps.

## Install

From the [OwnGoal Studio repository](https://github.com/owngoal-dev/owngoal-packages),
or grab the `.deb` for your bootstrap from
[Releases](../../releases) and `dpkg -i` it:

| bootstrap | package architecture |
| --------- | -------------------- |
| rootless  | `iphoneos-arm64`     |
| roothide  | `iphoneos-arm64e`    |

The architecture field names the **bootstrap layout**, not the CPU — both
packages carry the same arm64 binary. If you are unsure which you have, ask the
device: `dpkg --print-architecture`.

Requires iOS 15 or later and a bootstrap that provides a shell. Then run `codex`
in a terminal on device.

## What this repository is

Packaging, not a fork. There is no application source here: the build fetches
openai/codex at a pinned commit, applies the patches in `patches/`,
cross-compiles the CLI and its real `codex-code-mode-host` sidecar for
`aarch64-apple-ios`, and produces the two packages. V8 is built jitless from
the matching pinned `rusty_v8` source; no Direct fallback or placeholder host
is substituted.

The Rust binary is **not** linked with RootHide's libvroot. C tools in the
bootstrap (git, bash) can keep writing `/bin/sh` on roothide because vroot
rewrites those APIs at compile time; this process talks to libSystem directly,
so it has to probe for the bootstrap's shell. See `AGENTS.md`.

## Build it yourself

Needs macOS with Xcode, Rust (rustup), plus `ldid` and `dpkg`
(`brew install ldid dpkg`).

```sh
make check     # scripts, config, patch set
make debs      # both packages + SHA256SUMS, into build/Packages
```

To install on an attached device over USB:

```sh
iproxy 4422:2222 &
make install
```

`make help` lists the rest.

## Credits

Codex is by OpenAI, Apache-2.0. This repository only packages it; the iOS
patches are MIT.

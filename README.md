# sandbox-releases

Public release mirror for **sandbox**, an egress-restricted OCI sandbox launcher.

The source repository is private. This repository holds only the published macOS release
binaries (as GitHub Releases) and a minimal binary-distribution notice. The binaries are
provided **as is**; see [`LICENSE`](./LICENSE) for the warranty disclaimer and the permitted
and forbidden acts.

## Install

> A one-line installer (`curl … | bash`) is coming soon. Until then, install manually from
> a release:

1. Download the `.tar.gz` and `SHA256SUMS` from the
   [latest release](https://github.com/sector7co/sandbox-releases/releases/latest).
   Current builds target **macOS arm64 (Apple Silicon)**.
2. Verify integrity: `shasum -a 256 -c SHA256SUMS`
3. Extract & install onto your PATH (no sudo):
   `tar -xzf sandbox-*-aarch64-apple-darwin.tar.gz && mkdir -p ~/.local/bin && install -m 0755 sandbox ~/.local/bin/sandbox`
   — then make sure `~/.local/bin` is on your `PATH`
   (`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`).
4. Confirm: `sandbox --version`

Running a sandbox requires a container engine (Docker / OrbStack, or Apple `container`).
The `sandbox` binary itself is self-contained — recipes, registry, and image pins are
embedded; no `python3` or other runtime is needed.

## Integrity & signing status

Every release ships a `SHA256SUMS` covering all artifacts. This provides **integrity** — it
detects download corruption; verify with `shasum -a 256 -c SHA256SUMS`. It is **not** an
authenticity guarantee: `SHA256SUMS` is published unsigned alongside the binaries, so it does
not prove who produced them or that they were not tampered with at the source.

These macOS builds carry an **ad-hoc** signature (applied automatically by Apple's linker on
Apple Silicon; it conveys **no identity**). When `sandbox` is run from the Terminal as a
command-line tool, macOS Gatekeeper does not gate execution, so there is no "unidentified
developer" prompt regardless of how you downloaded the archive. If macOS ever flags it, clear
the quarantine attribute: `xattr -d com.apple.quarantine ./sandbox`. Developer ID signing +
notarization (which would add authenticity for browser / double-click launches) is not
currently applied.

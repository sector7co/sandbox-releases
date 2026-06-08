# sandbox-releases

Public release mirror for **sandbox**, an egress-restricted OCI sandbox launcher.

The source repository is private. This repository holds only the published macOS release
binaries (as GitHub Releases) and a minimal binary-distribution notice. The binaries are
provided **as is**; see [`LICENSE`](./LICENSE) for the warranty disclaimer and the permitted
and forbidden acts.

## Install

**macOS (Apple Silicon):**

```sh
curl -fsSL https://raw.githubusercontent.com/sector7co/sandbox-releases/main/install.sh | bash
```

This downloads the latest release, **verifies its SHA-256 before installing**, places the
self-contained `sandbox` binary in `~/.sandbox/bin`, and adds it to your `PATH` (via an
installer-owned `~/.sandbox/env` sourced from your shell startup file). Re-running upgrades in
place. (The script then fetches the release artifacts over HTTPS-only, TLS-pinned connections.)

It's a short, auditable POSIX script — **read it before you run it**:

```sh
curl -fsSL https://raw.githubusercontent.com/sector7co/sandbox-releases/main/install.sh | less
```

**Options** (environment variables):

- `SANDBOX_VERSION=v0.1.0` — install a specific release tag instead of the latest.
- `SANDBOX_INSTALL=/path` — install prefix (default `~/.sandbox`).

**Uninstall:**

```sh
curl -fsSL https://raw.githubusercontent.com/sector7co/sandbox-releases/main/install.sh | bash -s -- --uninstall
```

If you installed to a custom prefix, uninstall with the same value
(`SANDBOX_INSTALL=/your/path curl … | bash -s -- --uninstall`) — otherwise the uninstaller
removes the `PATH` lines from your shell startup files but cannot find the binary under the
default `~/.sandbox` to delete it.

<details>
<summary>Manual install (no installer)</summary>

1. Download the `.tar.gz` and `SHA256SUMS` from the
   [latest release](https://github.com/sector7co/sandbox-releases/releases/latest).
   Current builds target **macOS arm64 (Apple Silicon)**.
2. Verify integrity (checks only the file you downloaded, so it stays correct once more
   platforms ship): `grep 'aarch64-apple-darwin\.tar\.gz$' SHA256SUMS | shasum -a 256 -c -`
3. Extract & install onto your PATH (no sudo):
   `tar -xzf sandbox-*-aarch64-apple-darwin.tar.gz && mkdir -p ~/.local/bin && install -m 0755 sandbox ~/.local/bin/sandbox`
   — then make sure `~/.local/bin` is on your `PATH`
   (`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`).
4. Confirm: `sandbox --version`

> This manual path is independent of the `curl | bash` installer — it uses `~/.local/bin`, not
> `~/.sandbox`, so the installer's `--uninstall` will not remove it. To undo a manual install,
> delete `~/.local/bin/sandbox` and the `export PATH` line you added to `~/.zshrc` by hand.

</details>

Linux / x86_64 are not yet supported (the installer fails loud on other platforms;
tracked in the source repo's issue #58).

Running a sandbox requires a container engine (Docker / OrbStack, or Apple `container`).
The `sandbox` binary itself is self-contained — recipes, registry, and image pins are
embedded; no `python3` or other runtime is needed.

## Integrity & signing status

Every release ships a `SHA256SUMS` covering all artifacts. This provides **integrity** — it
detects download corruption; verify with `shasum -a 256 -c SHA256SUMS`. It is **not** an
authenticity guarantee: `SHA256SUMS` is published unsigned alongside the binaries, so it does
not prove who produced them or that they were not tampered with at the source. The installer
verifies this checksum fail-closed, but inherits the same limitation. Signing `SHA256SUMS`
(minisign/cosign) to add authenticity is tracked in the source repo's issue #81.

These macOS builds carry an **ad-hoc** signature (applied automatically by Apple's linker on
Apple Silicon; it conveys **no identity**). When `sandbox` is run from the Terminal as a
command-line tool, macOS Gatekeeper does not gate execution, so there is no "unidentified
developer" prompt regardless of how you downloaded the archive. If macOS ever flags it, clear
the quarantine attribute: `xattr -d com.apple.quarantine ./sandbox`. Developer ID signing +
notarization (which would add authenticity for browser / double-click launches) is not
currently applied.

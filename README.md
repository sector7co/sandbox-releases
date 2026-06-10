# sandbox-releases

Public release mirror for **sandbox**, an egress-restricted OCI sandbox launcher.

The source repository is private. This repository holds only the published macOS and Linux
release binaries (as GitHub Releases) and a minimal binary-distribution notice. The binaries are
provided **as is**; see [`LICENSE`](./LICENSE) for the warranty disclaimer and the permitted
and forbidden acts.

## Install

**macOS (Apple Silicon) and Linux (x86_64 / aarch64)** — the installer auto-detects your platform:

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

1. Download the `.tar.gz` for your platform and `SHA256SUMS` from the
   [latest release](https://github.com/sector7co/sandbox-releases/releases/latest). Builds target
   **macOS arm64** (`aarch64-apple-darwin`) and **Linux x86_64 / aarch64**
   (`x86_64-unknown-linux-musl` / `aarch64-unknown-linux-musl`, static — runs on any Linux).
2. Verify integrity. `SHA256SUMS` lists every platform, so verify just the tarball you downloaded —
   this form is portable across GNU coreutils, BusyBox/Alpine, and macOS:
   - Linux: `grep " $(ls sandbox-*-*.tar.gz)$" SHA256SUMS | sha256sum -c -`
   - macOS: `grep " $(ls sandbox-*-*.tar.gz)$" SHA256SUMS | shasum -a 256 -c -`
3. Extract & install onto your PATH (no sudo):
   `tar -xzf sandbox-*-*.tar.gz && mkdir -p ~/.local/bin && install -m 0755 sandbox ~/.local/bin/sandbox`
   — then make sure `~/.local/bin` is on your `PATH`
   (`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`).
4. Confirm: `sandbox --version`

> This manual path is independent of the `curl | bash` installer — it uses `~/.local/bin`, not
> `~/.sandbox`, so the installer's `--uninstall` will not remove it. To undo a manual install,
> delete `~/.local/bin/sandbox` and the `export PATH` line you added to `~/.zshrc` by hand.

</details>

Running a sandbox requires a container engine — Docker / OrbStack or Apple `container` on macOS,
Docker or Podman on Linux.
The `sandbox` binary itself is self-contained — recipes, registry, and image pins are
embedded; no `python3` or other runtime is needed.

## Integrity & signing status

Releases are signed with an SSH signature: each ships a `SHA256SUMS` covering all platform artifacts
plus a `SHA256SUMS.sig` produced by the release signing key, giving both **integrity** (the checksum
detects download corruption) and **authenticity** (the signature proves who produced the checksums).
Releases predating signing — including the current `v0.2.0` — ship `SHA256SUMS` only; the installer
detects the absent signature and continues on SHA-256 integrity alone (see below).

**Signing key (pinned).** `SHA256SUMS` is signed with a standalone Ed25519 SSH key; `install.sh` pins
its public key as the sole root of trust (there is no certificate chain — the installer trusts exactly
this key):

- Fingerprint: `SHA256:9me2h37vG/xYUnUbF+xJWyEz2j/ZqkOap7w5VAtxJVo`
- Signer identity `releases@sector7co`, namespace `sandbox-releases`.

**The installer verifies automatically.** When `ssh-keygen` (OpenSSH ≥ 8.2) is present, `install.sh`
verifies `SHA256SUMS.sig` against the pinned key **before** the checksum compare and **fails closed**
on a bad signature. If the verifier or the signature is absent (a host without OpenSSH ≥ 8.2, or an
older unsigned release such as `v0.2.0`), it warns and continues on SHA-256 integrity alone — so
verification never bricks an install.

**Verify manually.** Download `SHA256SUMS` and `SHA256SUMS.sig` alongside the tarball, then (portable
across GNU coreutils, BusyBox/Alpine, and macOS):

```sh
printf 'releases@sector7co ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFvEIM3JGElseZXWciGKmSH8KKLpe81FAvOQA8Lun93Y\n' > allowed_signers
ssh-keygen -Y verify -f allowed_signers -I releases@sector7co -n sandbox-releases -s SHA256SUMS.sig < SHA256SUMS
grep " $(ls sandbox-*-*.tar.gz)$" SHA256SUMS | sha256sum -c -    # macOS: … | shasum -a 256 -c -
```

**Rotation / residual.** On key rotation the pinned key in `install.sh` is bumped and future releases
are re-signed; because `install.sh` is fetched fresh, the pin is always current for the latest release
(an old `SANDBOX_VERSION`-pinned release signed by a retired key fails closed after a rotation — install
the latest instead). Because verification is opt-in (it cannot require `ssh-keygen` of everyone without
bricking minimal hosts), a mirror attacker who *strips* `SHA256SUMS.sig` downgrades a verifier-present
user to a warning rather than a hard failure; the checksum (integrity) is always enforced.

These macOS builds carry an **ad-hoc** signature (applied automatically by Apple's linker on
Apple Silicon; it conveys **no identity**). When `sandbox` is run from the Terminal as a
command-line tool, macOS Gatekeeper does not gate execution, so there is no "unidentified
developer" prompt regardless of how you downloaded the archive. If macOS ever flags it, clear
the quarantine attribute: `xattr -d com.apple.quarantine ./sandbox`. Developer ID signing +
notarization (which would add authenticity for browser / double-click launches) is not
currently applied.

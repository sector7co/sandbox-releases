#!/bin/sh
# sandbox installer — keep this SIMPLE and AUDITABLE. Read it before you pipe it to a shell:
#
#   curl -fsSL https://raw.githubusercontent.com/sector7co/sandbox-releases/main/install.sh | less
#
# What it does: resolves the latest (or $SANDBOX_VERSION) macOS-arm64 `sandbox` release from the
# public mirror, downloads the tarball + SHA256SUMS, verifies the SHA-256 FAIL-CLOSED (before
# extracting), installs the one self-contained binary to ~/.sandbox/bin, and wires PATH via an
# installer-owned ~/.sandbox/env sourced from your shell startup file. Re-running upgrades in
# place. Uninstall with: ... | bash -s -- --uninstall  (or SANDBOX_UNINSTALL=1).
#
# Integrity, NOT authenticity: SHA256SUMS is published UNSIGNED, in the same repo as the binary.
# The checksum detects a corrupt or swapped object IF SHA256SUMS itself arrives intact; it does
# NOT defend against a full mirror compromise that rewrites both. Signed checksums are tracked
# in sector7co/sandbox#81 (ties #46). See this repo's README "Integrity & signing status".
#
# Scope: macOS arm64 (Apple Silicon) only — fails loud elsewhere. Linux / x86_64 = sandbox#58.
set -eu

# ----- overridable configuration -----
REPO="${SANDBOX_RELEASES_REPO:-sector7co/sandbox-releases}"
PREFIX="${SANDBOX_INSTALL:-${HOME:?set SANDBOX_INSTALL or HOME}/.sandbox}"
BIN_DIR="$PREFIX/bin"
ENV_FILE="$PREFIX/env"
ASSET_ARCH="aarch64-apple-darwin"   # hardcoded; never derived from uname
# A collision-proof, full-line sentinel the installer alone writes into rc files. Both the
# install guard and the uninstaller key on this exact string, so neither touches user lines.
MARKER="# added by the sandbox installer (https://github.com/sector7co/sandbox-releases)"

# Color is filled in by setup_colors() only when stdout is a TTY; default empty (set -u safe).
_bold=''; _red=''; _yellow=''; _reset=''

# ----- helpers -----
setup_colors() {
    if [ -t 1 ]; then
        _bold="$(printf '\033[1m')"
        _red="$(printf '\033[31m')"
        _yellow="$(printf '\033[33m')"
        _reset="$(printf '\033[0m')"
    fi
}
info() { printf '%s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$_yellow" "$_reset" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_red" "$_reset" "$*" >&2; exit 1; }
need_cmd() {
    for _c in "$@"; do
        command -v "$_c" >/dev/null 2>&1 || die "required command not found on PATH: $_c"
    done
}

# Hardened transfers. -f: no HTTP-error body. -L: follow GitHub's 302 to the CDN.
# --proto '=https'/--tlsv1.2: refuse any non-HTTPS (incl. a downgrade in a redirect).
# --max-time bounds each attempt; --retry-max-time bounds the whole retry sequence
# (--retry resets --max-time per attempt, so --max-time alone is not an overall ceiling).
# We rely on curl's EXIT STATUS, never on stderr text.
http_get() {        # http_get URL  -> response body on stdout
    curl --proto '=https' --tlsv1.2 -fsSL \
         --retry 3 --connect-timeout 10 --max-time 120 --retry-max-time 180 \
         "$1"
}
http_get_file() {   # http_get_file URL DEST
    curl --proto '=https' --tlsv1.2 -fsSL \
         --retry 3 --connect-timeout 10 --max-time 300 --retry-max-time 360 \
         -o "$2" "$1"
}

check_platform() {
    _os="$(uname -s)"
    [ "$_os" = Darwin ] || die "macOS only — this installer supports darwin-arm64 (got '$_os'). Linux support: sandbox#58."
    _arch="$(uname -m)"
    case "$_arch" in
        arm64|aarch64) ;;
        *) die "Apple Silicon (arm64) only (got '$_arch'). x86_64 support: sandbox#58." ;;
    esac
}

# Echoes a normalized tag (e.g. v0.1.0). SANDBOX_VERSION pins a tag and skips the API.
resolve_tag() {
    if [ -n "${SANDBOX_VERSION:-}" ]; then
        case "$SANDBOX_VERSION" in
            v*) printf '%s' "$SANDBOX_VERSION" ;;
            *)  printf 'v%s' "$SANDBOX_VERSION" ;;
        esac
        return 0
    fi
    _json="$(http_get "https://api.github.com/repos/$REPO/releases/latest")" \
        || die "could not reach the release API for $REPO (network, or unauthenticated rate limit)"
    # Anchored on the value, not a brittle column position; never eval JSON.
    printf '%s' "$_json" \
        | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"\([^"]*\)"$/\1/'
}

# Installer-owned env file. Self-guarding (cargo-style) so re-sourcing across .zprofile+.zshrc
# and nested shells never duplicates the PATH entry. $BIN_DIR is baked in literally; $PATH stays
# verbatim for evaluation at source time.
write_env_file() {
    cat > "$ENV_FILE" <<EOF
# sandbox shell environment — installer-managed; safe to source repeatedly.
case ":\${PATH}:" in
    *:"$BIN_DIR":*) ;;
    *) export PATH="$BIN_DIR:\$PATH" ;;
esac
EOF
}

# The exact line the installer appends to an rc file (single source of truth for guard + remove).
source_line() { printf '. "%s"  %s' "$ENV_FILE" "$MARKER"; }

# Idempotently append the source-line to RC, creating RC if missing.
ensure_line() {
    _rc="$1"
    [ -e "$_rc" ] || : > "$_rc"
    grep -qF -- "$MARKER" "$_rc" 2>/dev/null || printf '\n%s\n' "$(source_line)" >> "$_rc"
}
# Append only if RC already exists — never create it (avoids shadowing ~/.profile for bash).
append_if_present() {
    _rc="$1"
    [ -f "$_rc" ] || return 0
    grep -qF -- "$MARKER" "$_rc" 2>/dev/null || printf '\n%s\n' "$(source_line)" >> "$_rc"
}

setup_path() {
    write_env_file
    ensure_line "$HOME/.profile"            # POSIX login catch-all (dash/ash/sh; bash w/o .bash_profile)
    _sh="${SHELL:-}"; _sh="${_sh##*/}"      # basename without the basename(1) dependency
    _recognized=1                           # shared global: also read by install_sandbox's smoke summary
    case "$_sh" in
        zsh)
            ensure_line "$HOME/.zshrc"          # all interactive zsh
            ensure_line "$HOME/.zprofile" ;;    # login zsh
        bash)
            ensure_line "$HOME/.bashrc"             # interactive non-login bash
            append_if_present "$HOME/.bash_profile" ;;  # login bash if it already exists
        *)
            _recognized=0 ;;
    esac

    if [ "$_recognized" -eq 1 ]; then
        info "Configured PATH via $ENV_FILE (sourced from your shell startup files)."
        info "Open a new terminal, or run this now:  . \"$ENV_FILE\""
    else
        warn "Did not recognize your shell (\$SHELL='${SHELL:-unset}'); PATH was wired only into ~/.profile."
        warn "If 'sandbox' is not found in a new shell, add this line to your shell's startup file:"
        warn "    . \"$ENV_FILE\""
        warn "fish/csh users: add '$BIN_DIR' to PATH manually ($ENV_FILE is POSIX-sh only)."
    fi
}

install_sandbox() {
    check_platform

    _tag="$(resolve_tag)"
    case "$_tag" in
        v[0-9]*) ;;
        *) die "could not resolve a valid release tag (got '${_tag:-}')" ;;
    esac
    # Defense-in-depth: reject any tag carrying shell metacharacters or whitespace, so the
    # value is safe even if a future edit drops the quoting it currently relies on. Accepts
    # v0.1.0 and prerelease forms like v0.2.0-rc.1; rejects ; $ ` | & spaces, etc.
    case "$_tag" in
        *[!0-9A-Za-z.-]*) die "release tag contains unexpected characters (got '$_tag')" ;;
    esac
    _ver="${_tag#v}"
    _asset="sandbox-${_ver}-${ASSET_ARCH}.tar.gz"

    # Stage UNDER $PREFIX so the final mv is a same-filesystem (atomic) rename.
    mkdir -p "$BIN_DIR" || die "could not create $BIN_DIR"
    _tmp="$(mktemp -d "$PREFIX/.tmp.XXXXXX")" || die "could not create a staging dir under $PREFIX"
    trap 'rm -rf "$_tmp"' EXIT

    _base="https://github.com/$REPO/releases/download/$_tag"
    info "Downloading sandbox $_ver ($ASSET_ARCH)…"
    http_get_file "$_base/$_asset"     "$_tmp/$_asset"     || die "download failed: $_base/$_asset"
    http_get_file "$_base/SHA256SUMS"  "$_tmp/SHA256SUMS"  || die "download failed: $_base/SHA256SUMS"

    # FAIL-CLOSED integrity: exact field-2 match (no regex on the name), die if absent, compare,
    # and only then extract. Never skip on a missing line or a missing tool. The leading-`*`/`./`
    # strip tolerates a binary-mode (`shasum -b`) or path-prefixed SHA256SUMS without loosening
    # to a substring/regex match.
    _expected="$(awk -v f="$_asset" '{ n=$2; sub(/^[*]/,"",n); sub(/^\.\//,"",n) } n == f { print $1 }' "$_tmp/SHA256SUMS")"
    [ -n "$_expected" ] || die "no checksum for $_asset in SHA256SUMS — refusing to install"
    _actual="$(shasum -a 256 "$_tmp/$_asset" | awk '{ print $1 }')"
    [ "$_expected" = "$_actual" ] || die "checksum mismatch for $_asset (expected $_expected, got $_actual) — refusing to install"
    info "Checksum verified."

    tar xzf "$_tmp/$_asset" -C "$_tmp" || die "could not extract $_asset"
    [ -f "$_tmp/sandbox" ] || die "archive did not contain the expected 'sandbox' binary"
    chmod +x "$_tmp/sandbox"                       # never trust archive perms
    mv -f "$_tmp/sandbox" "$BIN_DIR/sandbox"       # same-FS rename → atomic

    setup_path

    # Post-install smoke. Warn-only (never compare --version to the tag — a prerelease asset's
    # version differs from the binary's crate core). Gate the success block on it.
    if _v="$("$BIN_DIR/sandbox" --version 2>/dev/null)"; then
        info ""
        info "${_bold}Installed: ${_v}${_reset}"
        info "  location: $BIN_DIR/sandbox"
        if [ "$_recognized" -eq 1 ]; then
            info "  next:     sandbox --help   (running a sandbox needs a container engine: Docker/OrbStack or Apple container)"
        else
            info "  next:     $BIN_DIR/sandbox --help   (or finish wiring PATH per the note above; running a sandbox needs a container engine: Docker/OrbStack or Apple container)"
        fi
    else
        warn "sandbox was installed to $BIN_DIR/sandbox but did not run on this machine."
        warn "PATH was still configured. If this is unexpected, please report it."
    fi
}

uninstall() {
    need_cmd grep mv rm rmdir mktemp
    # Refuse obviously-wrong targets outright.
    case "$PREFIX" in
        ""|/|"$HOME") die "refusing to uninstall from '$PREFIX' (not a sandbox prefix)" ;;
    esac

    # Remove the source-line from a FIXED superset of rc files, regardless of the current $SHELL,
    # so a shell switch between install and uninstall leaves nothing dangling. Delete ONLY our
    # exact marker line; user content is preserved. Stage in $HOME (same FS as the rc) → atomic mv.
    _removed=0
    for _rc in "$HOME/.profile" "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        [ -f "$_rc" ] || continue
        grep -qF -- "$MARKER" "$_rc" 2>/dev/null || continue
        _mode="$(stat -f '%Lp' "$_rc" 2>/dev/null || true)"   # preserve the rc's perms across the rewrite
        _trc="$(mktemp "$HOME/.sandbox-rc.XXXXXX")" || die "mktemp failed"
        # grep exit 1 = every line was the marker (legit empty result); >=2 = a real read/write
        # error (e.g. disk full) — never commit a truncated rc in that case.
        _g=0; grep -vF -- "$MARKER" "$_rc" > "$_trc" || _g=$?
        [ "$_g" -le 1 ] || { rm -f "$_trc"; die "failed to rewrite $_rc (grep exit $_g); left unchanged"; }
        [ -z "$_mode" ] || chmod "$_mode" "$_trc" 2>/dev/null || true
        mv -f "$_trc" "$_rc" || die "failed to update $_rc"
        info "Removed sandbox PATH line from $_rc"
        _removed=$((_removed + 1))
    done

    # Remove installer-owned files. Never rm -rf the whole prefix: delete known children, then
    # rmdir the prefix only if it is now empty. Absent marker = no-op (idempotent), not an error.
    if [ -f "$BIN_DIR/sandbox" ] || [ -f "$ENV_FILE" ]; then
        rm -f "$BIN_DIR/sandbox" "$ENV_FILE"
        rmdir "$BIN_DIR" 2>/dev/null || true
        rmdir "$PREFIX"  2>/dev/null || info "Note: $PREFIX is not empty; left in place."
        info "Removed sandbox from $PREFIX"
    elif [ "$_removed" -gt 0 ]; then
        info "Removed $_removed shell PATH line(s), but found no install under $PREFIX."
        info "If you installed to a custom prefix, re-run with it set: SANDBOX_INSTALL=/your/path … --uninstall"
    else
        info "No sandbox install found at $PREFIX (nothing to remove)."
    fi
    info "Uninstall complete."
}

main() {
    setup_colors
    case "${1:-}" in
        --uninstall) uninstall; return 0 ;;
    esac
    [ "${SANDBOX_UNINSTALL:-}" = 1 ] && { uninstall; return 0; }

    need_cmd curl shasum tar awk uname mktemp grep head sed mkdir chmod mv rm
    install_sandbox
}

main "$@"

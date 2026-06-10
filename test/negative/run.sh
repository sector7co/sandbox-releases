#!/bin/sh
# Installer negative-regression harness (sandbox#91 + the #81 bad-signature case).
#
# Drives install.sh through its FAIL-CLOSED paths (platform gate / asset-404 / tamper /
# missing-checksum-line / bad-signature) and its don't-brick POLICY GUARDS (unsigned release with a
# verifier present; verifier too old) using curl/uname/ssh shims + job-generated fixtures. No network,
# no real release. Asserts exit code + no-partial-state (nothing under $PREFIX) for fail-closed cases,
# and install-succeeds-with-a-warning for the policy guards.
#
# Usage:  sh test/negative/run.sh [path/to/install.sh]   (defaults to the repo's install.sh)
# Exit 0 iff every case meets its assertion. Used as-is by .github/workflows/installer-negative-tests.yml.
set -u

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
INSTALL_SH="${1:-$SCRIPT_DIR/../../install.sh}"
[ -f "$INSTALL_SH" ] || { echo "FATAL: install.sh not found at $INSTALL_SH"; exit 1; }

REAL_PATH="$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixtures"; SHIMS="$WORK/shims"; SHIMS_SSH="$WORK/shims-ssh"
mkdir -p "$FIX/payload" "$SHIMS" "$SHIMS_SSH"
: > "$WORK/failures.log"

# ----- pick a SHA-256 tool (matches install.sh's detect_sha) -----
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA="shasum -a 256"
else echo "FATAL: no SHA-256 tool"; exit 1; fi

# ----- fixtures -----
ASSET="sandbox-9.9.9-x86_64-unknown-linux-musl.tar.gz"   # what install.sh derives for Linux/x86_64 @ v9.9.9
printf '#!/bin/sh\necho "sandbox 0.0.0"\n' > "$FIX/payload/sandbox"
chmod +x "$FIX/payload/sandbox"
( cd "$FIX/payload" && tar czf "$FIX/$ASSET" sandbox )

hash="$($SHA "$FIX/$ASSET" | awk '{print $1}')"
printf '%s  %s\n' "$hash" "$ASSET" > "$FIX/SHA256SUMS"                       # correct
bad="$(printf '%s' "$hash" | sed 's/^./0/')"; [ "$bad" = "$hash" ] && bad="$(printf '%s' "$hash" | sed 's/^./1/')"
printf '%s  %s\n' "$bad" "$ASSET" > "$FIX/SHA256SUMS.tampered"               # flipped hash
printf '%s  sandbox-9.9.9-aarch64-apple-darwin.tar.gz\n' "$hash" > "$FIX/SHA256SUMS.missing"  # no line for our asset

# Bad/wrong-key signature: sign the GOOD SHA256SUMS with a FRESH EPHEMERAL key (won't verify against the
# pinned key by construction; no access to the real secret needed). Sign a FRESH path — `ssh-keygen -Y
# sign` does NOT overwrite an existing <file>.sig, so reusing a path would silently keep a stale sig.
ssh-keygen -t ed25519 -N "" -C ephemeral -f "$FIX/ephem" >/dev/null 2>&1
cp "$FIX/SHA256SUMS" "$FIX/SHA256SUMS.forsig"
ssh-keygen -Y sign -f "$FIX/ephem" -n sandbox-releases "$FIX/SHA256SUMS.forsig" >/dev/null 2>&1
mv "$FIX/SHA256SUMS.forsig.sig" "$FIX/SHA256SUMS.sig"

# Non-vacuity self-check: the ephemeral sig MUST itself verify under an ephemeral allow-list — proving
# the bad-signature case (below) is rejected for "key not in allow-list", NOT a malformed signature.
printf 'releases@sector7co %s\n' "$(cat "$FIX/ephem.pub")" > "$FIX/allowed_ephem"
if ssh-keygen -Y verify -f "$FIX/allowed_ephem" -I releases@sector7co -n sandbox-releases \
     -s "$FIX/SHA256SUMS.sig" < "$FIX/SHA256SUMS" >/dev/null 2>&1; then
  echo "self-check: bad-sig fixture is a VALID signature under its own (ephemeral) key — non-vacuous OK"
else
  echo "FATAL: bad-sig fixture does not even verify under its own key — case bad-signature would be vacuous"; exit 1
fi

# ----- shims -----
cat > "$SHIMS/uname" <<'SH'
#!/bin/sh
case "${1:-}" in
  -s) printf '%s\n' "${SHIM_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${SHIM_UNAME_M:-x86_64}" ;;
  *)  printf '%s\n' "${SHIM_UNAME_S:-Linux}" ;;
esac
SH

cat > "$SHIMS/curl" <<'SH'
#!/bin/sh
# Minimal curl shim: serves a fixture by the request URL's suffix, honoring `-o DEST`. Exits 22 (curl's
# 404-under-`-f` code) when the selected SHIM_* fixture is empty/unset. Consumes the value-taking flags
# install.sh passes (--proto/--retry/--connect-timeout/--max-time/--retry-max-time/-o) so the URL (last
# bare arg) is found reliably.
dest=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="${2:-}"; shift 2 ;;
    --proto|--retry|--connect-timeout|--max-time|--retry-max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *SHA256SUMS.sig) src="${SHIM_SIG:-}" ;;
  *SHA256SUMS)     src="${SHIM_SHA256SUMS:-}" ;;
  *.tar.gz)        src="${SHIM_TARBALL:-}" ;;
  *)               src="" ;;
esac
[ -n "$src" ] && [ -f "$src" ] || exit 22
if [ -n "$dest" ]; then cp "$src" "$dest"; else cat "$src"; fi
SH

cat > "$SHIMS_SSH/ssh" <<'SH'
#!/bin/sh
# Fake an OpenSSH older than the 8.2 verify floor (only `ssh -V`, on stderr, is used by install.sh).
case "${1:-}" in
  -V) echo "OpenSSH_7.4p1, LibreSSL 2.6.5" >&2 ;;
  *)  exit 0 ;;
esac
SH
chmod +x "$SHIMS/uname" "$SHIMS/curl" "$SHIMS_SSH/ssh"

# ----- case runner -----
FAILED=0
# run_case NAME EXPECT(fail|ok) UNAME_S UNAME_M SS_PATH SIG_PATH TB_PATH SSH_OLD(0|1) GREP
run_case() {
  name="$1"; expect="$2"; us="$3"; um="$4"; ss="$5"; sig="$6"; tb="$7"; sshold="$8"; grepstr="$9"
  H="$(mktemp -d)"; Pdir="$(mktemp -d)"; P="$Pdir/sandbox"
  cp="$SHIMS:$REAL_PATH"; [ "$sshold" = 1 ] && cp="$SHIMS_SSH:$cp"
  log="$WORK/log.$name"
  PATH="$cp" HOME="$H" SANDBOX_INSTALL="$P" SANDBOX_VERSION="v9.9.9" SHELL="/bin/sh" \
    SHIM_UNAME_S="$us" SHIM_UNAME_M="$um" SHIM_SHA256SUMS="$ss" SHIM_SIG="$sig" SHIM_TARBALL="$tb" \
    sh "$INSTALL_SH" >"$log" 2>&1
  rc=$?
  installed=0; [ -x "$P/bin/sandbox" ] && installed=1
  ok=1; reason=""
  if [ "$expect" = fail ]; then
    [ "$rc" -ne 0 ]    || { ok=0; reason="expected non-zero exit, got 0"; }
    [ "$installed" -eq 0 ] || { ok=0; reason="$reason; binary WAS installed (no-partial-state violated)"; }
  else
    [ "$rc" -eq 0 ]    || { ok=0; reason="expected exit 0, got $rc"; }
    [ "$installed" -eq 1 ] || { ok=0; reason="$reason; binary NOT installed"; }
  fi
  if [ -n "$grepstr" ]; then grep -q "$grepstr" "$log" || { ok=0; reason="$reason; log missing /$grepstr/"; }; fi
  if [ "$ok" -eq 1 ]; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s — %s\n' "$name" "$reason"
    FAILED=$((FAILED + 1))
    { echo "===== $name (rc=$rc installed=$installed) ====="; cat "$log"; echo; } >> "$WORK/failures.log"
  fi
  rm -rf "$H" "$Pdir"
}

echo "--- running negative cases against: $INSTALL_SH ---"
#         NAME             EXPECT  UNAME_S UNAME_M  SS                         SIG                    TB              SSH_OLD GREP
run_case  platform-gate    fail    Darwin  x86_64   ""                         ""                     ""              0       "not built"
run_case  asset-404        fail    Linux   x86_64   "$FIX/SHA256SUMS"          ""                     ""              0       "download failed"
run_case  tamper           fail    Linux   x86_64   "$FIX/SHA256SUMS.tampered" ""                     "$FIX/$ASSET"   0       "checksum mismatch"
run_case  missing-line     fail    Linux   x86_64   "$FIX/SHA256SUMS.missing"  ""                     "$FIX/$ASSET"   0       "refusing to install"
run_case  bad-signature    fail    Linux   x86_64   "$FIX/SHA256SUMS"          "$FIX/SHA256SUMS.sig"  "$FIX/$ASSET"   0       "signature"
run_case  unsigned-present ok      Linux   x86_64   "$FIX/SHA256SUMS"          ""                     "$FIX/$ASSET"   0       "not signed"
run_case  verifier-old     ok      Linux   x86_64   "$FIX/SHA256SUMS"          "$FIX/SHA256SUMS.sig"  "$FIX/$ASSET"   1       "skipping authenticity"

# ----- contract guard: install.sh still carries the exact #60 rc MARKER string -----
MARKER='# added by the sandbox installer (https://github.com/sector7co/sandbox-releases)'
if grep -qF "$MARKER" "$INSTALL_SH"; then
  printf 'PASS  marker-contract\n'
else
  printf 'FAIL  marker-contract — install.sh no longer contains the exact #60 rc MARKER string\n'
  FAILED=$((FAILED + 1))
fi

echo "-----------------------------------------------"
if [ "$FAILED" -eq 0 ]; then
  echo "ALL NEGATIVE CASES PASSED"
  exit 0
fi
echo "FAILED CASES: $FAILED"
echo "----- failure logs -----"; cat "$WORK/failures.log"
exit 1

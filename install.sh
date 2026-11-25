#!/usr/bin/env bash
#
# Antigravity CLI installer for x86-64 Linux CPUs lacking PCLMUL
# (Intel pre-Westmere / Core 2 era, AMD pre-Bulldozer, old VM CPU models).
#
# The official agy binary aborts on these CPUs with:
#   FATAL ERROR: This binary was compiled with pclmul enabled, but this
#   feature is not available on this processor (go/sigill-fast-fail).
# This script installs the official binary plus a qemu-user wrapper that
# emulates the missing instructions. See README.md for details.
#
set -euo pipefail

MANIFEST_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json"
BIN_DIR="$HOME/.local/bin"
WRAPPER="$BIN_DIR/agy"
LIBEXEC="$HOME/.local/libexec"
REAL_BIN="$LIBEXEC/agy.real"

log()  { printf '==> %s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || fail "This script supports Linux only."
[ "$(uname -m)" = "x86_64" ] || fail "This script targets x86_64. For other architectures use the official installer: https://antigravity.google/cli"

for cmd in curl tar sha512sum timeout; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

log "Fetching release manifest"
manifest="$(curl -fsSL "$MANIFEST_URL")" || fail "Failed to fetch the release manifest."
version="$(printf '%s' "$manifest" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
url="$(printf '%s' "$manifest" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
sha512="$(printf '%s' "$manifest" | sed -n 's/.*"sha512"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "$version" ] && [ -n "$url" ] && [ -n "$sha512" ] || fail "Failed to parse the release manifest."

log "Downloading agy $version"
curl -fsSL "$url" -o "$STAGING/agy.tar.gz" || fail "Download failed."

actual="$(sha512sum "$STAGING/agy.tar.gz" | cut -d' ' -f1)"
[ "$actual" = "$sha512" ] || fail "SHA-512 mismatch, aborting."

tar -xzf "$STAGING/agy.tar.gz" -C "$STAGING" antigravity || fail "Failed to extract the binary."

mkdir -p "$BIN_DIR"

# Determine whether this CPU can run the official build natively.
native_ok=0
native_status=0
# The subshell keeps bash's "Illegal instruction (core dumped)" job message quiet.
(
  timeout 60 "$STAGING/antigravity" --version >"$STAGING/native.log" 2>&1
) 2>/dev/null || native_status=$?
native_out="$(tr -d '\000' < "$STAGING/native.log")"
if [ "$native_status" -eq 0 ]; then
  case "$native_out" in
    *"FATAL ERROR"*) ;;
    *) native_ok=1 ;;
  esac
fi

if [ "$native_ok" = 1 ]; then
  log "Official binary runs natively on this CPU"
  if [ -e "$WRAPPER" ]; then
    mv -f "$WRAPPER" "$WRAPPER.bak.$(date +%Y%m%d-%H%M%S)"
    log "Backed up existing $WRAPPER"
  fi
  install -m 755 "$STAGING/antigravity" "$WRAPPER"
  log "Installed: $WRAPPER"
else
  case "$native_out" in
    *pclmul*) log "CPU lacks PCLMUL; setting up qemu-user emulation" ;;
    *) printf 'Native run failed with:\n%s\n' "$native_out" >&2
       log "Falling back to qemu-user emulation" ;;
  esac

  QEMU_BIN="$(command -v qemu-x86_64 || true)"
  if [ -z "$QEMU_BIN" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      log "Installing qemu-user via apt (sudo required)"
      sudo apt-get update -qq && sudo apt-get install -y qemu-user || true
      QEMU_BIN="$(command -v qemu-x86_64 || true)"
    fi
    [ -n "$QEMU_BIN" ] || fail "qemu-x86_64 not found. Install the qemu-user package (Debian/Ubuntu: sudo apt install qemu-user) and re-run."
  fi
  log "Using qemu-user: $QEMU_BIN"

  mkdir -p "$LIBEXEC"
  if [ -f "$REAL_BIN" ]; then
    cp -p "$REAL_BIN" "$REAL_BIN.bak.$(date +%Y%m%d-%H%M%S)"
    log "Backed up previous binary"
  fi
  install -m 755 "$STAGING/antigravity" "$REAL_BIN"
  log "Installed: $REAL_BIN"

  if [ -f "$WRAPPER" ] && head -n1 "$WRAPPER" 2>/dev/null | grep -q '^#!'; then
    log "Keeping existing wrapper: $WRAPPER"
  else
    if [ -e "$WRAPPER" ]; then
      mv -f "$WRAPPER" "$WRAPPER.bak.$(date +%Y%m%d-%H%M%S)"
      log "Moved non-wrapper file aside: $WRAPPER (backup kept)"
    fi
    cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# qemu-user wrapper for the official Antigravity CLI binary.
# The CPU lacks instructions required by the official build (PCLMUL etc.),
# so the real binary runs on an emulated full-featured CPU.
set -u
real="$HOME/.local/libexec/agy.real"
qemu="$(command -v qemu-x86_64)" || { echo "agy: qemu-x86_64 not found (install qemu-user)" >&2; exit 127; }
[ -x "$real" ] || { echo "agy: missing $real" >&2; exit 127; }
exec env \
  "AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS=${AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS:-1}" \
  "$qemu" -cpu max "$real" "$@"
WRAPPER_EOF
    chmod 755 "$WRAPPER"
    log "Created wrapper: $WRAPPER"
  fi
fi

# Ensure ~/.local/bin is on PATH for new shells.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    touched=0
    for rc in "$HOME/.profile" "$HOME/.zshrc" "$HOME/.bashrc"; do
      [ -f "$rc" ] || continue
      if ! grep -q '\.local/bin' "$rc"; then
        printf '\n# Added by antigravity-cli-legacy-cpu-fix\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
        touched=1
      fi
    done
    if [ "$touched" = 0 ] && [ ! -e "$HOME/.profile" ]; then
      printf '# Added by antigravity-cli-legacy-cpu-fix\nexport PATH="$HOME/.local/bin:$PATH"\n' > "$HOME/.profile"
      touched=1
    fi
    if [ "$touched" = 1 ]; then
      log "Added $BIN_DIR to PATH (new shells only)"
    fi
    ;;
esac

log "Verifying installation (qemu emulation takes a few seconds)"
if verify_out="$(timeout 300 "$WRAPPER" --version 2>&1)"; then
  log "agy $verify_out is ready"
else
  printf '%s\n' "$verify_out" >&2
  fail "Verification failed. Binary backups are in $LIBEXEC."
fi

cat <<'EOF'

Done. Start with: agy

Notes:
  - Do not run the official curl installer while ~/.local/bin/agy is missing:
    it installs a native binary that cannot run on this CPU.
  - The CLI's built-in auto-updater keeps updating ~/.local/libexec/agy.real
    under qemu; the wrapper is left untouched.
EOF
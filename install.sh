#!/usr/bin/env bash
#
# Antigravity CLI installer for x86-64 Linux CPUs lacking PCLMUL
# (Intel pre-Westmere / Core 2 era, AMD pre-Bulldozer, old VM CPU models).
#
# The official agy binary aborts on these CPUs with:
#   FATAL ERROR: This binary was compiled with pclmul enabled, but this
#   feature is not available on this processor (go/sigill-fail-fast).
# This script installs the official binary plus a qemu-user 8.2 wrapper that
# emulates the missing instructions. qemu 6.2 (the version in Ubuntu 22.04)
# mis-emulates the 1.5.x language server and can crash it; 8.2.2 is tested.
#
set -euo pipefail

MANIFEST_URL="${AGY_MANIFEST_URL:-https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json}"
BIN_DIR="$HOME/.local/bin"
WRAPPER="$BIN_DIR/agy"
LIBEXEC="$HOME/.local/libexec"
REAL_BIN="$LIBEXEC/agy.real"
QEMU_DIR="$LIBEXEC/qemu-8.2"
QEMU_BIN="$QEMU_DIR/qemu-x86_64-static"
QEMU_DEB_URL="${QEMU_DEB_URL:-https://archive.ubuntu.com/ubuntu/pool/universe/q/qemu/qemu-user-static_8.2.2+ds-0ubuntu1.20_amd64.deb}"
QEMU_DEB_SHA256="${QEMU_DEB_SHA256:-e94a0792dcb65442162635e5c59edde797de30e883e3b6f41927cb9fcdd1dcb2}"

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
manifest="$(printf '%s' "$manifest" | tr -d '\r\n')"
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

backup_wrapper() {
  if [ -e "$WRAPPER" ] || [ -L "$WRAPPER" ]; then
    local bak="$WRAPPER.bak.$(date +%Y%m%d-%H%M%S)"
    mv -f "$WRAPPER" "$bak"
    log "Backed up existing $WRAPPER to $bak"
  fi
}

qemu_ok() {
  local out version
  out="$("$1" --version 2>/dev/null | head -n1)" || return 1
  version="$(printf '%s\n' "$out" | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p')"
  [ -n "$version" ] || return 1
  [ "$(printf '8.2\n%s\n' "$version" | sort -V | head -n1)" = "8.2" ]
}

install_qemu() {
  local src="$1"
  mkdir -p "$QEMU_DIR"
  if [ -e "$QEMU_BIN" ] || [ -L "$QEMU_BIN" ]; then
    mv -f "$QEMU_BIN" "$QEMU_BIN.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  fi
  install -m 755 "$src" "$QEMU_BIN"
  log "Installed: $QEMU_BIN"
}

ensure_qemu() {
  if [ -x "$QEMU_BIN" ] && qemu_ok "$QEMU_BIN"; then
    log "Using existing qemu 8.2: $QEMU_BIN"
    return 0
  fi

  if [ -n "${QEMU_STATIC:-}" ]; then
    [ -x "$QEMU_STATIC" ] || fail "QEMU_STATIC is not executable: $QEMU_STATIC"
    qemu_ok "$QEMU_STATIC" || fail "QEMU_STATIC is not qemu 8.2 or newer: $QEMU_STATIC"
    install_qemu "$QEMU_STATIC"
    return 0
  fi

  command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb not found. Install dpkg or set QEMU_STATIC to an existing qemu 8.2+ static binary."
  command -v sha256sum >/dev/null 2>&1 || fail "Required command not found: sha256sum"

  log "Downloading qemu-user-static 8.2.2 from the Ubuntu archive"
  curl -fsSL "$QEMU_DEB_URL" -o "$STAGING/qemu.deb" || fail "Failed to download qemu-user-static."
  actual="$(sha256sum "$STAGING/qemu.deb" | cut -d' ' -f1)"
  [ "$actual" = "$QEMU_DEB_SHA256" ] || fail "qemu-user-static SHA-256 mismatch, aborting."

  mkdir -p "$STAGING/qemu"
  dpkg-deb -x "$STAGING/qemu.deb" "$STAGING/qemu" || fail "Failed to extract qemu-user-static."
  qemu_src="$STAGING/qemu/usr/bin/qemu-x86_64-static"
  [ -x "$qemu_src" ] || fail "qemu-x86_64-static not found in the package."
  qemu_ok "$qemu_src" || fail "Downloaded qemu is older than 8.2."
  install_qemu "$qemu_src"
}

# Determine whether this CPU can run the official build natively.
native_ok=0
native_status=0
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
  backup_wrapper
  install -m 755 "$STAGING/antigravity" "$WRAPPER"
  log "Installed: $WRAPPER"
else
  case "$native_out" in
    *pclmul*) log "CPU lacks PCLMUL; setting up qemu-user emulation" ;;
    *) printf 'Native run failed with:\n%s\n' "$native_out" >&2
       log "Falling back to qemu-user emulation" ;;
  esac

  ensure_qemu

  mkdir -p "$LIBEXEC"
  if [ -f "$REAL_BIN" ]; then
    cp -p "$REAL_BIN" "$REAL_BIN.bak.$(date +%Y%m%d-%H%M%S)"
    log "Backed up previous binary"
  fi
  install -m 755 "$STAGING/antigravity" "$REAL_BIN"
  log "Installed: $REAL_BIN"

  backup_wrapper
  cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# qemu-user wrapper for the official Antigravity CLI binary.
# The CPU lacks PCLMUL, so the real binary runs on an emulated full-featured CPU.
set -u

real="$HOME/.local/libexec/agy.real"
qemu="$HOME/.local/libexec/qemu-8.2/qemu-x86_64-static"

[ -x "$real" ] || { echo "agy: missing $real" >&2; exit 127; }
[ -x "$qemu" ] || { echo "agy: qemu 8.2 not found; re-run install.sh" >&2; exit 127; }

# Keep the built-in updater from spawning a native --bg-updater child, which
# SIGILLs on this CPU. Touch the check timestamp so the CLI takes its fast path.
mkdir -p "$HOME/.gemini/antigravity-cli" 2>/dev/null || true
touch "$HOME/.gemini/antigravity-cli/last_check.timestamp" 2>/dev/null || true

exec env \
  "AGY_CLI_DISABLE_AUTO_UPDATE=${AGY_CLI_DISABLE_AUTO_UPDATE:-1}" \
  "AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS=${AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS:-1}" \
  "$qemu" -cpu max "$real" "$@"
WRAPPER_EOF
  chmod 755 "$WRAPPER"
  log "Created wrapper: $WRAPPER"
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
  fail "Verification failed. Backups are next to the installed files."
fi

if [ "$native_ok" = 1 ]; then
  cat <<'EOF'

Done. Start with: agy

Notes:
  - The official binary runs natively on this CPU.
  - The CLI's built-in auto-updater is left enabled.
EOF
else
  cat <<'EOF'

Done. Start with: agy

Notes:
  - Auto-updates are disabled (AGY_CLI_DISABLE_AUTO_UPDATE=1): the updater
    child runs natively and SIGILLs on this CPU. Re-run install.sh to update.
  - Do not run the official curl installer while ~/.local/bin/agy is missing:
    it installs a native binary that cannot run on this CPU.
  - Backups are next to the installed files. The qemu binary is under
    ~/.local/libexec/qemu-8.2/.
EOF
fi

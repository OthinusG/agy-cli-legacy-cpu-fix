# Antigravity CLI on pre-PCLMUL x86-64 CPUs

Unofficial workaround that makes Google's Antigravity CLI (`agy`) start on x86-64 Linux CPUs that are too old for the official build, by running the official binary under `qemu-user` with full CPU feature emulation.

Tested on an Intel Core 2 Duo P7550 (Penryn, 2009) running Ubuntu, `qemu-user` 6.2.0, `agy` 1.5.9 → 1.5.17.

## Symptom

```text
$ curl -fsSL https://antigravity.google/cli/install.sh | bash
⠋ Detecting system environment...
✓ Platform detected: linux_amd64
✓ Latest available version: 1.5.17
✓ Download complete and checksum verified.
⠋ Extracting binary from archive...
⠋ Configuring shell environment...
FATAL ERROR: This binary was compiled with pclmul enabled, but this feature is not available on this processor (go/sigill-fail-fast).
bash: line 240: 1752006 Illegal instruction     (core dumped) "$BINARY_PATH" install
```

## Root cause

The official `agy` binary is a Go program built with a raised `GOAMD64` baseline and PCLMUL-enabled code paths. At startup the Go runtime checks that the CPU provides every feature the binary was compiled with; if not, it aborts via `go/sigill-fail-fast` instead of dying later with `SIGILL`.

PCLMUL (carry-less multiplication, used for AES-GCM/GHASH and other crypto hot paths) first appeared with Intel Westmere (2010) and AMD Bulldozer (2011). CPUs older than that have no such instruction — e.g. Intel Core 2 era (Penryn, 2008–2009) parts, which also lack SSE4.2. These CPUs cannot run the official binary natively, and no flag or configuration changes that: the instructions simply do not exist on the silicon.

The same failure shows up in VMs whose CPU model is older than the host (for example `qemu64` / pre-Westmere KVM models). On a VM the proper fix is usually to expose the host CPU (`host-passthrough`); this repo is for real legacy hardware.

## Fix

Emulate a full-featured CPU with `qemu-user`:

```text
~/.local/bin/agy                 (wrapper script, stays in place)
        └─ qemu-x86_64 -cpu max  (emulates the missing instructions)
              └─ ~/.local/libexec/agy.real   (official agy binary)
```

Why the built-in auto-updater keeps working: the updater replaces its own executable via `/proc/self/exe`. Under `qemu-user`, that path resolves to the guest binary `agy.real`, so updates are applied to the real binary and continue to run through the wrapper. The official installer, however, hardcodes `~/.local/bin/agy` and executes the binary natively — if the wrapper is missing, it writes the native binary there and the install step crashes.

## One-command install

Requirements: x86-64 Linux, `bash`, `curl`, `tar`, `sha512sum`, and `qemu-user` (the script installs it via `apt` if missing and `sudo` is available).

```bash
git clone https://github.com/OthinusG/agy-cli-legacy-cpu-fix.git
cd agy-cli-legacy-cpu-fix
bash install.sh
```

What `install.sh` does:

1. Fetches the official release manifest and downloads the latest `agy` tarball.
2. Verifies the SHA-512 checksum from the manifest.
3. Tries to run the binary natively. If that works (modern CPU), it installs the binary directly.
4. Otherwise installs `qemu-user` if needed, places the binary at `~/.local/libexec/agy.real`, and writes the wrapper at `~/.local/bin/agy` (an existing wrapper is preserved).
5. Adds `~/.local/bin` to `PATH` in your shell profile if needed.
6. Verifies by running `agy --version` through the wrapper.

## Verify

```bash
agy --version   # takes ~5-6 s on a 2.26 GHz Core 2 Duo because of TCG emulation
agy --help
```

## Updating

- Automatic: the CLI's built-in auto-updater replaces `~/.local/libexec/agy.real` and keeps working through the wrapper (verified: 1.5.9 auto-updated from the release server).
- Manual: re-run `bash install.sh`. It replaces `agy.real` and leaves any existing wrapper untouched.
- Rollback: backups are kept next to the binary.

```bash
ls -lat ~/.local/libexec/ | head
cp ~/.local/libexec/agy.real.bak.<timestamp> ~/.local/libexec/agy.real
```

## Manual install (without the script)

```bash
# 1. Back up the current binary
cp ~/.local/libexec/agy.real ~/.local/libexec/agy.real.bak 2>/dev/null || true

# 2. Download and verify the latest release
MANIFEST=$(curl -fsSL https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json)
URL=$(echo "$MANIFEST" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
SHA=$(echo "$MANIFEST" | sed -n 's/.*"sha512"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
curl -fsSL "$URL" -o /tmp/agy.tar.gz && echo "$SHA  /tmp/agy.tar.gz" | sha512sum -c -
tar -xzf /tmp/agy.tar.gz -C /tmp antigravity && mv -f /tmp/antigravity ~/.local/libexec/agy.real && chmod 755 ~/.local/libexec/agy.real

# 3. Wrapper at ~/.local/bin/agy
cat > ~/.local/bin/agy <<'EOF'
#!/usr/bin/env bash
set -u
real="$HOME/.local/libexec/agy.real"
qemu="$(command -v qemu-x86_64)" || { echo "agy: qemu-x86_64 not found (install qemu-user)" >&2; exit 127; }
[ -x "$real" ] || { echo "agy: missing $real" >&2; exit 127; }
exec env "AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS=${AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS:-1}" \
  "$qemu" -cpu max "$real" "$@"
EOF
chmod 755 ~/.local/bin/agy
```

## Notes

- **Do not run the official `curl ... | bash` installer while the wrapper is missing.** It writes a native binary to `~/.local/bin/agy`; the resulting `agy install` crashes with `Illegal instruction`. If the wrapper exists, the installer refuses to overwrite it.
- Emulation is not free: TCG translates every instruction. On a 2.26 GHz Core 2 Duo, `agy --version` takes ~5-6 s; interactive sessions work but are slower than on supported hardware.
- `AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS=1` is set by the wrapper to keep the TUI rendering stable under emulation. You can override it via the environment.
- macOS and ARM are not covered by this repo.
- Not affiliated with Google. Nothing is redistributed here: binaries are downloaded from Google's public release endpoint at install time.
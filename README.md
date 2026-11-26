# Antigravity CLI on pre-PCLMUL x86-64 CPUs

Unofficial workaround that makes Google's Antigravity CLI (`agy`) start on x86-64 Linux CPUs that are too old for the official build, by running the official binary under `qemu-user` with full CPU feature emulation.

Tested on an Intel Core 2 Duo P7550 (Penryn, 2009) running Linux Mint 21.3 (Ubuntu 22.04 base), with `qemu-user` 8.2.2 static and `agy` 1.5.17. `agy` 1.5.9 also runs under `qemu-user` 8.2.2.

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

The official `agy` binary is a Go program built with a raised `GOAMD64` baseline and PCLMUL-enabled code paths. At startup the Go runtime checks that the CPU provides every feature the binary was compiled with; if not, it aborts instead of dying later with `SIGILL`.

PCLMUL (carry-less multiplication, used for AES-GCM/GHASH and other crypto hot paths) first appeared with Intel Westmere (2010) and AMD Bulldozer (2011). CPUs older than that have no such instruction — e.g. Intel Core 2 era (Penryn, 2008–2009) parts, which also lack SSE4.2. These CPUs cannot run the official binary natively, and no flag or configuration changes that: the instructions simply do not exist on the silicon.

The same failure shows up in VMs whose CPU model is older than the host (for example `qemu64` / pre-Westmere KVM models). On a VM the proper fix is usually to expose the host CPU (`host-passthrough`); this repo is for real legacy hardware.

## Why qemu 8.2, not the distro qemu 6.2

The first version of this workaround used the `qemu-user` 6.2 package from Ubuntu 22.04. That works for `agy` 1.4.9, but `agy` 1.5.x's language server can crash under qemu 6.2 with a `fatal error: fault` in `conversationsearch`, even though the CLI itself starts. The same binaries run cleanly under qemu 8.2.2, so this repo uses a static 8.2.2 binary extracted from the Ubuntu 24.04 `qemu-user-static` package.

The wrapper also disables the CLI's built-in auto-updater. On this CPU the updater spawns a native `--bg-updater` child outside qemu, and that child dies with `SIGILL`. Setting `AGY_CLI_DISABLE_AUTO_UPDATE=1` and touching `~/.gemini/antigravity-cli/last_check.timestamp` keeps it on the fast path and prevents the spawn. Updates are installed by re-running `install.sh` instead.

## Fix

Emulate a full-featured CPU with `qemu-user` 8.2:

```text
~/.local/bin/agy                 (wrapper script, stays in place)
        └─ qemu-x86_64 -cpu max  (emulates the missing instructions)
              └─ ~/.local/libexec/agy.real   (official agy binary)
```

The wrapper at `~/.local/bin/agy` is what the official installer checks for; it refuses to overwrite an existing file, so keep it in place.

## One-command install

Requirements: x86-64 Linux, `bash`, `curl`, `tar`, `sha256sum`, `sha512sum`, and `dpkg-deb` (for extracting the Ubuntu qemu package). No root or `sudo` is needed.

```bash
git clone https://github.com/OthinusG/agy-cli-legacy-cpu-fix.git
cd agy-cli-legacy-cpu-fix
bash install.sh
```

What `install.sh` does:

1. Fetches the official release manifest and downloads the latest `agy` tarball.
2. Verifies the SHA-512 checksum from the manifest.
3. Tries to run the binary natively. If that works (modern CPU), it installs the binary directly and stops there.
4. Otherwise installs `qemu-x86_64-static` 8.2.2 into `~/.local/libexec/qemu-8.2/`, verifies the Ubuntu package's SHA-256, and places the official binary at `~/.local/libexec/agy.real`.
5. Backs up any existing `~/.local/bin/agy` and writes the qemu wrapper there. An old wrapper that points at qemu 6.2 is replaced, not preserved.
6. Adds `~/.local/bin` to `PATH` in your shell profile if needed.
7. Verifies by running `agy --version` through the wrapper.

If you are not on Debian/Ubuntu, or you already have a qemu 8.2+ static binary, set `QEMU_STATIC=/path/to/qemu-x86_64-static` and the installer will use it instead of downloading the `.deb`. `QEMU_DEB_URL` and `QEMU_DEB_SHA256` can point at a mirror; `AGY_MANIFEST_URL` can point at a mirror of the release manifest.

## Verify

```bash
agy --version   # takes ~5-6 s on a 2.26 GHz Core 2 Duo because of TCG emulation
agy --help
```

## Updating

- Automatic updates are intentionally disabled on this CPU. The updater child runs natively and crashes with `SIGILL`; the wrapper therefore sets `AGY_CLI_DISABLE_AUTO_UPDATE=1`.
- To update, re-run `bash install.sh`. It downloads the latest official binary, replaces `agy.real`, and replaces the wrapper with the current version.
- Rollback: backups are kept next to the binary and wrapper.

```bash
ls -lat ~/.local/libexec/ | head
cp ~/.local/libexec/agy.real.bak.<timestamp> ~/.local/libexec/agy.real
```

## Manual install (without the script)

```bash
# 1. Download and verify the latest official release
MANIFEST=$(curl -fsSL https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json)
URL=$(echo "$MANIFEST" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
SHA=$(echo "$MANIFEST" | sed -n 's/.*"sha512"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
curl -fsSL "$URL" -o /tmp/agy.tar.gz && echo "$SHA  /tmp/agy.tar.gz" | sha512sum -c -
mkdir -p ~/.local/libexec ~/.local/bin
tar -xzf /tmp/agy.tar.gz -C /tmp antigravity && mv -f /tmp/antigravity ~/.local/libexec/agy.real && chmod 755 ~/.local/libexec/agy.real

# 2. Install qemu 8.2.2 static from the Ubuntu 24.04 package
QEMU_DEB=/tmp/qemu-user-static_8.2.2+ds-0ubuntu1.20_amd64.deb
curl -fSL -o "$QEMU_DEB" \
  "https://archive.ubuntu.com/ubuntu/pool/universe/q/qemu/qemu-user-static_8.2.2+ds-0ubuntu1.20_amd64.deb"
echo "e94a0792dcb65442162635e5c59edde797de30e883e3b6f41927cb9fcdd1dcb2  $QEMU_DEB" | sha256sum -c -
rm -rf /tmp/qemu-extract && mkdir -p /tmp/qemu-extract
dpkg-deb -x "$QEMU_DEB" /tmp/qemu-extract
mkdir -p ~/.local/libexec/qemu-8.2
install -m 755 /tmp/qemu-extract/usr/bin/qemu-x86_64-static \
  ~/.local/libexec/qemu-8.2/qemu-x86_64-static

# 3. Wrapper at ~/.local/bin/agy
cat > ~/.local/bin/agy <<'EOF'
#!/usr/bin/env bash
set -u
real="$HOME/.local/libexec/agy.real"
qemu="$HOME/.local/libexec/qemu-8.2/qemu-x86_64-static"
[ -x "$real" ] || { echo "agy: missing $real" >&2; exit 127; }
[ -x "$qemu" ] || { echo "agy: missing $qemu; install qemu 8.2" >&2; exit 127; }
mkdir -p "$HOME/.gemini/antigravity-cli" 2>/dev/null || true
touch "$HOME/.gemini/antigravity-cli/last_check.timestamp" 2>/dev/null || true
exec env \
  "AGY_CLI_DISABLE_AUTO_UPDATE=${AGY_CLI_DISABLE_AUTO_UPDATE:-1}" \
  "AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS=${AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS:-1}" \
  "$qemu" -cpu max "$real" "$@"
EOF
chmod 755 ~/.local/bin/agy
```

## Notes

- **Do not run the official `curl ... | bash` installer while the wrapper is missing.** It writes a native binary to `~/.local/bin/agy`, and the resulting `agy install` crashes with `Illegal instruction`. If the wrapper exists, the official installer refuses to overwrite it.
- Emulation is not free: TCG translates every instruction. On a 2.26 GHz Core 2 Duo, `agy --version` takes ~5-6 s; interactive sessions work but are slower than on supported hardware.
- `AGY_CLI_DISABLE_ESCAPE_SEQUENCE_OPTIMIZATIONS=1` is set by the wrapper to keep the TUI rendering stable under emulation. You can override it via the environment.
- If you need a proxy, export `https_proxy`/`http_proxy` before starting `agy`; the wrapper passes the environment through.
- macOS and ARM are not covered by this repo.
- Not affiliated with Google. Nothing is redistributed here: the CLI is downloaded from Google's public release endpoint, and the qemu package is downloaded from the Ubuntu archive at install time.

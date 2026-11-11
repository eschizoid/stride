#!/bin/sh
# Install the stride command line from a GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/eschizoid/stride/main/install.sh | sh
#
# Environment:
#   STRIDE_VERSION      a release tag such as v0.20.0 (default: the latest release)
#   STRIDE_INSTALL_DIR  where the binary goes (default: ~/.local/bin)
#   STRIDE_INSTALL_APP  macOS only: 1 installs the desktop window into ~/Applications
#                       without asking, 0 skips it; unset asks when a terminal is attached
#
# The binary is checked against the release's SHA256SUMS.txt before it is installed.
# Windows has no shell installer: download stride-cli-windows-x86_64 from the release.
set -eu

# Everything runs from main, called on the last line: a download cut off
# part way through defines a partial function and runs nothing.
main() {
  repo="eschizoid/stride"
  version="${STRIDE_VERSION:-latest}"
  dir="${STRIDE_INSTALL_DIR:-$HOME/.local/bin}"

  say() { printf '%s\n' "$*"; }
  fail() { printf 'stride install: %s\n' "$*" >&2; exit 1; }

  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      fail "on Windows, download stride-cli-windows-x86_64 (and stride-app-windows-x86_64.zip for the window) from https://github.com/$repo/releases/latest" ;;
    *) fail "no release build for $(uname -s); build from source: https://github.com/$repo#build-from-source" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64)
      arch=x86_64
      # a shell translated by Rosetta reports x86_64 on Apple Silicon
      if [ "$os" = macos ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then arch=arm64; fi ;;
    arm64 | aarch64) arch=arm64 ;;
    *) fail "no release build for the $(uname -m) CPU; build from source: https://github.com/$repo#build-from-source" ;;
  esac

  case "$version" in
    latest) base="https://github.com/$repo/releases/latest/download" ;;
    v*) base="https://github.com/$repo/releases/download/$version" ;;
    *) base="https://github.com/$repo/releases/download/v$version" ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL -o "$2" "$1"; }
  elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q -O "$2" "$1"; }
  else
    fail "needs curl or wget"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha() { sha256sum "$1" | cut -d' ' -f1; }
  elif command -v shasum >/dev/null 2>&1; then
    sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
  else
    fail "needs sha256sum or shasum to verify the download"
  fi

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM

  fetch "$base/SHA256SUMS.txt" "$tmp/SHA256SUMS.txt" || fail "could not download $base/SHA256SUMS.txt"

  # download one release asset into $tmp and check it against SHA256SUMS.txt
  get() {
    fetch "$base/$1" "$tmp/$1" || fail "could not download $base/$1"
    want=$(awk -v f="$1" '$2 == f { print $1 }' "$tmp/SHA256SUMS.txt")
    [ -n "$want" ] || fail "$1 is not listed in SHA256SUMS.txt"
    got=$(sha "$tmp/$1")
    [ "$got" = "$want" ] || fail "$1 failed its checksum (expected $want, got $got)"
  }

  asset="stride-cli-$os-$arch"
  say "downloading $asset ($version)"
  get "$asset"
  mkdir -p "$dir"
  chmod 755 "$tmp/$asset"
  mv -f "$tmp/$asset" "$dir/stride"
  say "installed $dir/stride ($("$dir/stride" --version 2>/dev/null || echo "version unknown"))"

  cmd=stride
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) cmd="$dir/stride" ; say "" ; say "note: $dir is not on your PATH. Add this to your shell profile:" ; say "  export PATH=\"$dir:\$PATH\"" ;;
  esac

  # The desktop window ships as a separate app on macOS. `curl | sh` feeds this
  # script on stdin, so the question is asked on the terminal itself.
  if [ "$os" = macos ]; then
    want_app="${STRIDE_INSTALL_APP:-}"
    if [ -z "$want_app" ] && { : >/dev/tty; } 2>/dev/null; then
      printf 'Also install the desktop window (Stride.app) into ~/Applications? [y/N] ' > /dev/tty
      read -r answer < /dev/tty || answer=""
      case "$answer" in y | Y | yes | YES) want_app=1 ;; *) want_app=0 ;; esac
    fi
    if [ "$want_app" = 1 ]; then
      app="stride-app-macos-$arch.zip"
      get "$app"
      mkdir -p "$HOME/Applications"
      rm -rf "$HOME/Applications/Stride.app"
      (cd "$HOME/Applications" && unzip -q "$tmp/$app")
      say "installed $HOME/Applications/Stride.app"
    fi
  fi

  say ""
  say "next: run \`$cmd setup\` to connect Strava, set your timezone and heart-rate zones, and pull your history."
}

main "$@"

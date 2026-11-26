#!/bin/sh
# Install the stride command line, and the desktop app if you want it, from a
# GitHub release on macOS or Linux:
#
#   curl -fsSL https://raw.githubusercontent.com/eschizoid/stride/main/install.sh | sh
#
# Running it again installs the newer release over the old one in place; the
# athlete's directory (~/.stride) and the app's menu entry are kept. On
# Windows, install.ps1 in this repository does the same.
#
# Environment:
#   STRIDE_VERSION       a release tag such as v0.20.0 (default: the latest release)
#   STRIDE_INSTALL_DIR   where the command goes (default: ~/.local/bin)
#   STRIDE_INSTALL_APP   1 installs the desktop app without asking, 0 skips it;
#                        unset asks when a terminal is attached. The app goes to
#                        ~/Applications/Stride.app on macOS and to
#                        ~/.local/share/stride-app on Linux x86_64, whose install
#                        step then adds it to the application menu
#   STRIDE_DOWNLOAD_BASE a folder holding a release's assets, as a URL, read in
#                        place of the GitHub release; a file:// URL needs curl
#
# Every download is checked against the release's SHA256SUMS.txt before it is
# installed, so a checksum only vouches for what the same place serves.
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
      fail "on Windows, run this in PowerShell instead: irm https://raw.githubusercontent.com/$repo/main/install.ps1 | iex" ;;
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

  if [ -n "${STRIDE_DOWNLOAD_BASE:-}" ]; then
    base="${STRIDE_DOWNLOAD_BASE%/}"
    version="from $base"
  else
    case "$version" in
      latest) base="https://github.com/$repo/releases/latest/download" ;;
      v*) base="https://github.com/$repo/releases/download/$version" ;;
      *) base="https://github.com/$repo/releases/download/v$version" ;;
    esac
  fi

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
    want=$(awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS.txt")
    [ -n "$want" ] || fail "$1 is not listed in SHA256SUMS.txt"
    got=$(sha "$tmp/$1")
    [ "$got" = "$want" ] || fail "$1 failed its checksum (expected $want, got $got)"
  }

  # moves a new file or folder ($1) to $2: it lands beside $2 first, then is
  # renamed over it, so a running copy of the old one keeps running and no
  # reader ever sees half of the new one. A link at $2 is replaced, never
  # followed
  put() {
    rm -rf "$2.new" "$2.old"
    mv "$1" "$2.new"
    if [ -L "$2" ]; then rm -f "$2"; elif [ -d "$2" ]; then mv "$2" "$2.old"; fi
    mv -f "$2.new" "$2"
    rm -rf "$2.old"
  }

  asset="stride-cli-$os-$arch"
  say "downloading $asset ($version)"
  get "$asset"
  mkdir -p "$dir"
  chmod 755 "$tmp/$asset"
  put "$tmp/$asset" "$dir/stride"
  say "installed $dir/stride ($("$dir/stride" --version 2>/dev/null || echo "version unknown"))"

  cmd=stride
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) cmd="$dir/stride" ; say "" ; say "note: $dir is not on your PATH. Add this to your shell profile:" ; say "  export PATH=\"$dir:\$PATH\"" ;;
  esac

  # roc-ray builds the window for macOS and for linux x86_64 alone
  app=""
  case "$os-$arch" in
    macos-*) app="stride-app-macos-$arch.zip" ; app_home="$HOME/Applications/Stride.app" ;;
    linux-x86_64) app="stride-app-linux-x86_64.tar.gz" ; app_home="${XDG_DATA_HOME:-$HOME/.local/share}/stride-app" ;;
  esac

  # `curl | sh` feeds this script on stdin, so the question is asked on the
  # terminal itself
  want_app="${STRIDE_INSTALL_APP:-}"
  if [ -z "$app" ]; then
    [ "$want_app" = 1 ] && say "note: there is no desktop app for $os $arch; the command is installed"
    want_app=0
  elif [ -z "$want_app" ] && { : >/dev/tty; } 2>/dev/null; then
    printf 'Also install the desktop app into %s? [y/N] ' "$app_home" > /dev/tty
    read -r answer < /dev/tty || answer=""
    case "$answer" in y | Y | yes | YES) want_app=1 ;; *) want_app=0 ;; esac
  fi
  if [ "$want_app" = 1 ]; then
    get "$app"
    mkdir -p "$tmp/app" "$(dirname "$app_home")"
    if [ "$os" = macos ]; then
      (cd "$tmp/app" && unzip -q "$tmp/$app")
      [ -d "$tmp/app/Stride.app" ] || fail "$app holds no Stride.app"
      put "$tmp/app/Stride.app" "$app_home"
      say "installed $app_home"
    else
      tar -xzf "$tmp/$app" -C "$tmp/app"
      [ -x "$tmp/app/stride-app/stride-app" ] || fail "$app holds no stride-app launcher"
      put "$tmp/app/stride-app" "$app_home"
      say "installed $app_home"
      # the package's install step adds the menu entry; the app is not started
      if [ -x "$app_home/install.sh" ]; then
        STRIDE_APP_START=0 STRIDE_INSTALL_DIR="$dir" "$app_home/install.sh"
      else
        say "note: this release's app has no install step; start it with $app_home/stride-app"
      fi
    fi
  fi

  say ""
  say "next: run \`$cmd setup\` to connect Strava, set your timezone and heart-rate zones, and pull your history."
}

main "$@"

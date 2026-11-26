#!/usr/bin/env bash
# Proves install.sh, the one-line installer, in fake homes only: it never
# reads or writes the caller's ~/.stride or ~/.local.
#
#   install-check.sh release <older tag>   the GitHub releases
#   install-check.sh local <folder>        packages built from this checkout
#
# `release` runs install.sh, under sh and under dash where it is installed,
# cut off at every line and short of its last bytes, and checks that no cut
# installs anything while the whole file, run the same way, installs;
# installs the latest release under each shell with STRIDE_INSTALL_APP
# unset and no terminal, and checks that the install prints the line that
# puts the command's folder on the PATH and ends by naming `stride setup`,
# that the command starts and that no app arrives; checks that a folder
# where the command goes stops the install untouched, and that a TERM
# during a download ends it with status 143 and leaves nothing; then
# installs the older tag with the app, checks that an app failing its
# checksum leaves the older command and app in place, installs the latest
# over it, and checks the command and the app are the latest's, replaced in
# place, the athlete's directory and the menu entry kept, and no file
# carries macOS's quarantine attribute.
#
# `local` takes a folder holding this checkout's command and app package
# under their release names, writes its SHA256SUMS.txt, installs the latest
# release with the app and then the folder over it through
# STRIDE_DOWNLOAD_BASE, twice, and checks that the command is the folder's
# byte for byte, that the app carries that same command, that on linux the
# menu entry names the installed app, and that the athlete's directory and
# the menu entry survive each update.
#
# Every mode first runs the function install.sh reads the app question's
# answer with, and checks that n and no in any case decline and anything
# else accepts.
#
# Run from the repository root. The latest release and the older tag are
# read from GitHub, so both modes need the network.
set -euo pipefail

[ -f install.sh ] || { echo "install-check: run from the repository root" >&2; exit 2; }
mode="${1:-}"
here="$PWD"

if command -v sha256sum >/dev/null 2>&1; then sum="sha256sum"; else sum="shasum -a 256"; fi
hash_of() { $sum "$1" | cut -d' ' -f1; }

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  *) echo "install-check: install.sh serves macOS and Linux; install.ps1 has its own check" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) echo "install-check: no release build for $(uname -m)" >&2; exit 2 ;;
esac
if [ "$os" = macos ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then arch=arm64; fi
has_app=1
[ "$os-$arch" = linux-arm64 ] && has_app=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# the shells install.sh runs under: sh, and dash where it is installed,
# the strict POSIX shell Debian and Ubuntu run as sh. The cut-off and fresh
# installs run under each, and every other install under the last of them
shells="sh"
command -v dash >/dev/null 2>&1 && shells="sh dash"
inst_sh="${shells##* }"

# runs install.sh from a fake home ($1) under $inst_sh, with no terminal
# and every variable the installer reads set by the caller's environment
# alone
run_install() {
  local home="$1"; shift
  (cd "$home" && env -u STRIDE_VERSION -u STRIDE_INSTALL_APP -u STRIDE_DOWNLOAD_BASE HOME="$home" XDG_DATA_HOME="" STRIDE_INSTALL_DIR="$home/bin" "$@" "$inst_sh" "$here/install.sh" </dev/null)
}

app_home() {
  if [ "$os" = macos ]; then echo "$1/Applications/Stride.app"; else echo "$1/.local/share/stride-app"; fi
}

# the latest release's tag, as GitHub's redirect for releases/latest names it
latest_tag() {
  curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/eschizoid/stride/releases/latest | sed 's|.*/tag/||'
}

# every file under the paths given that carries macOS's quarantine
# attribute, one per line; the attribute a browser download carries is
# planted on a scratch file first, so a listing that cannot see it fails
# instead of reading as clean
quarantined() {
  local probe="$work/quarantine-probe" found
  : > "$probe"
  xattr -w com.apple.quarantine "0081;00000000;Safari;" "$probe"
  found="$(find "$probe" -exec sh -c 'xattr -p com.apple.quarantine "$1" >/dev/null 2>&1 && echo "$1"' _ {} \;)"
  [ "$found" = "$probe" ] || { echo "::error::the quarantine probe cannot see an attribute planted on $probe" >&2; exit 1; }
  find "$@" -exec sh -c 'xattr -p com.apple.quarantine "$1" >/dev/null 2>&1 && echo "$1"' _ {} \; || true
}

check_no_quarantine() {
  [ "$os" = macos ] || return 0
  local q
  q="$(quarantined "$@")"
  [ -z "$q" ] || { echo "::error::the installer left the quarantine attribute on: $q"; exit 1; }
  echo "install-check: no installed file carries the quarantine attribute"
}

# the athlete's directory: a database, fonts and images the window seeded
plant_athlete_dir() {
  mkdir -p "$1/.stride/fonts" "$1/.stride/img"
  printf 'athlete data\n' > "$1/.stride/db.sqlite"
  printf 'font\n' > "$1/.stride/fonts/Seeded.ttf"
  printf 'image\n' > "$1/.stride/img/seeded.png"
}

check_athlete_dir() {
  [ "$(cat "$1/.stride/db.sqlite" 2>/dev/null)" = "athlete data" ] &&
    [ "$(cat "$1/.stride/fonts/Seeded.ttf" 2>/dev/null)" = font ] &&
    [ "$(cat "$1/.stride/img/seeded.png" 2>/dev/null)" = image ] ||
    { echo "::error::an update changed the athlete's directory $1/.stride"; exit 1; }
}

# the installed app answers for the version given (macOS reads it from the
# bundle; the linux package carries no version, so a marker left in the
# old folder must be gone, which only a replaced folder shows)
check_app_replaced() {
  local app; app="$(app_home "$1")"
  [ ! -e "$app/.from-the-older-install" ] || { echo "::error::the update left the older app in $app"; exit 1; }
  if [ "$os" = macos ]; then
    local v; v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
    [ "$v" = "$2" ] || { echo "::error::the installed app says $v, not $2"; exit 1; }
    [ -x "$app/Contents/MacOS/stride-viz" ] || { echo "::error::the installed app has no window binary"; exit 1; }
  else
    [ -x "$app/stride-app" ] && [ -x "$app/stride-viz" ] || { echo "::error::the installed app lacks its launcher or window"; exit 1; }
  fi
  for leftover in "$app.new" "$app.old" "$1/bin/stride.new" "$1/bin/stride.old"; do
    [ ! -e "$leftover" ] || { echo "::error::the installer left $leftover behind"; exit 1; }
  done
}

# the linux menu entry exists and runs the installed app's launcher; a
# package without an install step writes none, and that is reported
check_entry() {
  [ "$os" = linux ] || return 0
  local app entry; app="$(app_home "$1")"; entry="$1/.local/share/applications/stride.desktop"
  if [ ! -e "$app/install.sh" ]; then
    echo "install-check: this release's linux app has no install step, so no menu entry is checked"
    return 0
  fi
  [ -s "$entry" ] || { echo "::error::no menu entry at $entry"; exit 1; }
  grep -qxF "Exec=\"$app/stride-app\"" "$entry" || { echo "::error::the menu entry does not run $app/stride-app: $(grep '^Exec=' "$entry")"; exit 1; }
}

# the app question's answer, read by install.sh's own answer_is_no, the
# one-line function it defines: n and no in any case decline, as in
# install.ps1, and anything else accepts, Enter included. Every mode runs
# this, before anything is downloaded
answer_fn="$(grep -E '^  answer_is_no\(\) \{.*\}$' install.sh || true)"
[ -n "$answer_fn" ] || { echo "::error::install.sh defines no one-line answer_is_no"; exit 1; }
eval "$answer_fn"
for a in n N no No nO NO; do
  answer_is_no "$a" || { echo "::error::install.sh reads the answer '$a' as yes"; exit 1; }
done
for a in "" y Y yes YES nope "n o" non; do
  ! answer_is_no "$a" || { echo "::error::install.sh reads the answer '$a' as no"; exit 1; }
done
echo "install-check: install.sh reads n and no in any case as no, and any other answer as yes"

case "$mode" in
  release)
    older="${2:?an older release tag to update from}"
    latest="$(latest_tag)"
    [ -n "$latest" ] && [ "$latest" != "$older" ] || { echo "::error::the latest release is '$latest', which is no update over $older"; exit 1; }

    # a download cut off anywhere installs nothing, while the whole file,
    # run the same way, installs, under each shell
    n="$(wc -l < install.sh | tr -d ' ')"
    home="$work/cut"
    for s in $shells; do
      for cut in $(seq 1 $((n - 1))) bytes whole; do
        rm -rf "$home"; mkdir -p "$home"
        case "$cut" in
          bytes) head -c $(($(wc -c < install.sh) - 4)) install.sh > "$work/cut.sh" ;;
          whole) cp install.sh "$work/cut.sh" ;;
          *) head -n "$cut" install.sh > "$work/cut.sh" ;;
        esac
        (cd "$home" && env -u STRIDE_VERSION -u STRIDE_DOWNLOAD_BASE HOME="$home" XDG_DATA_HOME="" STRIDE_INSTALL_DIR="$home/bin" STRIDE_INSTALL_APP=0 "$s" "$work/cut.sh" </dev/null >/dev/null 2>&1) || true
        if [ "$cut" = whole ]; then
          [ -x "$home/bin/stride" ] || { echo "::error::the whole install.sh, run under $s as each cut was, installed nothing"; exit 1; }
        else
          [ -z "$(ls -A "$home")" ] || { echo "::error::install.sh cut after $cut lines wrote $(ls -A "$home") under $s"; exit 1; }
        fi
      done
    done
    echo "install-check: install.sh cut at each of its $n lines, and short of its last bytes, installs nothing, and whole it installs, under $shells"

    # the latest release, STRIDE_INSTALL_APP unset and no terminal, under
    # each shell: the command alone, and the install ends with its last line
    for s in $shells; do
      home="$work/fresh-$s"; mkdir -p "$home"
      out="$(inst_sh="$s" run_install "$home" 2>&1)" || { printf '%s\n' "$out"; echo "::error::install.sh under $s failed with no terminal"; exit 1; }
      # its last line names `stride setup` by the path that runs it, since
      # the fake home's bin is not on this PATH, and it prints the line that
      # puts that folder there
      case "$(tail -n 1 <<<"$out")" in
        "next: run \`$home/bin/stride setup\`"*) ;;
        *) printf '%s\n' "$out"; echo "::error::install.sh under $s did not end by naming $home/bin/stride setup"; exit 1 ;;
      esac
      grep -qxF "  export PATH=\"$home/bin:\$PATH\"" <<<"$out" || { printf '%s\n' "$out"; echo "::error::install.sh under $s did not print the export line for $home/bin"; exit 1; }
      out="$("$home/bin/stride" --version)"
      [ "$out" = "stride ${latest#v}" ] || { echo "::error::the installed command says '$out', not stride ${latest#v}"; exit 1; }
      [ ! -e "$(app_home "$home")" ] || { echo "::error::the app arrived without being asked for"; exit 1; }
    done
    echo "install-check: the latest release installs $out and no app unasked, under $shells"

    # a folder where the command would go is left alone, and nothing is
    # installed
    home="$work/folder"; mkdir -p "$home/bin/stride"
    : > "$home/bin/stride/kept"
    if out="$(run_install "$home" STRIDE_INSTALL_APP=1 2>&1)"; then
      echo "::error::install.sh installed over the folder $home/bin/stride"; exit 1
    fi
    grep -q 'is not a file' <<<"$out" || { printf '%s\n' "$out"; echo "::error::install.sh did not say why it refused the folder"; exit 1; }
    [ -e "$home/bin/stride/kept" ] && [ "$(ls -A "$home/bin")" = stride ] && [ ! -e "$(app_home "$home")" ] ||
      { echo "::error::install.sh changed $home while refusing the folder: $(ls -A "$home/bin")"; exit 1; }
    echo "install-check: a folder at the command's name stops the install, untouched"

    # a TERM while the checksums download ends the install with status 143
    # and removes its downloads: the list is a pipe, opened by the fetch
    # and written only after the signal is sent
    home="$work/term"; mkdir -p "$home/tmp" "$work/pipe"
    mkfifo "$work/pipe/SHA256SUMS.txt"
    env -u STRIDE_VERSION HOME="$home" XDG_DATA_HOME="" TMPDIR="$home/tmp" STRIDE_INSTALL_DIR="$home/bin" STRIDE_INSTALL_APP=0 \
      STRIDE_DOWNLOAD_BASE="file://$work/pipe" "$inst_sh" "$here/install.sh" </dev/null >"$work/term.log" 2>&1 &
    pid=$!
    for _ in $(seq 100); do [ -n "$(ls -A "$home/tmp")" ] && break; sleep 0.1; done
    [ -n "$(ls -A "$home/tmp")" ] || { kill "$pid" 2>/dev/null; echo "::error::install.sh never started its download"; exit 1; }
    sleep 1
    kill -TERM "$pid"
    printf 'interrupted\n' > "$work/pipe/SHA256SUMS.txt" &
    writer=$!
    rc=0; wait "$pid" || rc=$?
    kill "$writer" 2>/dev/null || true
    [ "$rc" = 143 ] || { cat "$work/term.log"; echo "::error::install.sh ended with $rc after a TERM, not 143"; exit 1; }
    [ -z "$(ls -A "$home/tmp")" ] && [ ! -e "$home/bin" ] ||
      { echo "::error::install.sh left $(ls -A "$home/tmp" "$home") after a TERM"; exit 1; }
    echo "install-check: a TERM mid-download ends the install with 143 and leaves nothing"

    # the older release with the app, then the latest over it
    home="$work/update"; mkdir -p "$home"
    plant_athlete_dir "$home"
    run_install "$home" STRIDE_VERSION="$older" STRIDE_INSTALL_APP=1
    out="$("$home/bin/stride" --version)"
    [ "$out" = "stride ${older#v}" ] || { echo "::error::$older installed a command saying '$out'"; exit 1; }
    if [ "$has_app" = 1 ]; then
      [ -d "$(app_home "$home")" ] || { echo "::error::$older's app was not installed"; exit 1; }
      : > "$(app_home "$home")/.from-the-older-install"

      # an app that fails its checksum stops the update before the command
      # is replaced, so the command and the app stay one release's
      mirror="$work/mirror"; mkdir -p "$mirror"
      cli="stride-cli-$os-$arch"
      case "$os" in macos) pkg="stride-app-macos-$arch.zip" ;; linux) pkg="stride-app-linux-x86_64.tar.gz" ;; esac
      for f in "$cli" "$pkg"; do curl -fsSL -o "$mirror/$f" "https://github.com/eschizoid/stride/releases/latest/download/$f"; done
      printf '%s  %s\n%s  %s\n' "$(hash_of "$mirror/$cli")" "$cli" "$(printf '0%.0s' $(seq 64))" "$pkg" > "$mirror/SHA256SUMS.txt"
      if out="$(run_install "$home" STRIDE_INSTALL_APP=1 STRIDE_DOWNLOAD_BASE="file://$mirror" 2>&1)"; then
        echo "::error::install.sh installed an app that failed its checksum"; exit 1
      fi
      grep -q "$pkg failed its checksum" <<<"$out" || { printf '%s\n' "$out"; echo "::error::install.sh did not refuse the app for its checksum"; exit 1; }
      out="$("$home/bin/stride" --version)"
      [ "$out" = "stride ${older#v}" ] || { echo "::error::an app that failed its checksum still left the command saying '$out', not stride ${older#v}"; exit 1; }
      [ -e "$(app_home "$home")/.from-the-older-install" ] || { echo "::error::an app that failed its checksum still replaced the older app"; exit 1; }
      echo "install-check: an app failing its checksum leaves the older command and app in place"
    fi
    run_install "$home" STRIDE_INSTALL_APP=1
    out="$("$home/bin/stride" --version)"
    [ "$out" = "stride ${latest#v}" ] || { echo "::error::the update left a command saying '$out', not stride ${latest#v}"; exit 1; }
    check_athlete_dir "$home"
    if [ "$has_app" = 1 ]; then
      check_app_replaced "$home" "${latest#v}"
      check_entry "$home"
      check_no_quarantine "$home/bin" "$(app_home "$home")"
    else
      check_no_quarantine "$home/bin"
    fi
    echo "install-check: $latest installs over $older in place, and the athlete's directory is kept"
    ;;

  local)
    src="${2:?the folder holding the command and app package built from this checkout}"
    src="$(cd "$src" && pwd)"
    cli="stride-cli-$os-$arch"
    [ -s "$src/$cli" ] || { echo "::error::$src holds no $cli"; exit 1; }
    case "$os" in
      macos) pkg="stride-app-macos-$arch.zip" ;;
      linux) pkg="stride-app-linux-x86_64.tar.gz" ;;
    esac
    [ "$has_app" = 1 ] || { echo "::error::there is no app for $os $arch to check"; exit 1; }
    [ -s "$src/$pkg" ] || { echo "::error::$src holds no $pkg"; exit 1; }
    (cd "$src" && $sum "$cli" "$pkg" > SHA256SUMS.txt)
    want="$(hash_of "$src/$cli")"

    home="$work/local"; mkdir -p "$home"
    plant_athlete_dir "$home"
    run_install "$home" STRIDE_INSTALL_APP=1
    : > "$(app_home "$home")/.from-the-older-install"
    for round in 1 2; do
      run_install "$home" STRIDE_INSTALL_APP=1 STRIDE_DOWNLOAD_BASE="file://$src"
      [ "$(hash_of "$home/bin/stride")" = "$want" ] || { echo "::error::round $round installed a command that is not $src/$cli"; exit 1; }
      app="$(app_home "$home")"
      if [ "$os" = macos ]; then bundled="$app/Contents/MacOS/stride"; else bundled="$app/bin/stride"; fi
      [ -x "$bundled" ] && [ "$(hash_of "$bundled")" = "$want" ] ||
        { echo "::error::round $round installed an app whose command is not $src/$cli"; exit 1; }
      check_athlete_dir "$home"
      check_app_replaced "$home" "$("$src/$cli" --version | sed 's/^stride //')"
      check_entry "$home"
      [ "$os" = macos ] || [ -s "$home/.local/share/applications/stride.desktop" ] ||
        { echo "::error::round $round wrote no menu entry"; exit 1; }
      check_no_quarantine "$home/bin" "$app"
      : > "$app/.from-the-older-install"
    done
    echo "install-check: this checkout's packages install over the latest release, and over themselves, in place"
    ;;

  *)
    echo "usage: install-check.sh release <older tag> | local <folder>" >&2
    exit 2
    ;;
esac

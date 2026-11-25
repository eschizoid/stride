#!/usr/bin/env bash
# Packages the window for linux and windows, the two platforms with no bundle
# format, and proves each package. The release workflow ships what this builds,
# and build.yml runs the same steps on every pull request, so a package that
# lacks a file the window reads fails before a release carries it.
#
#   package-viz.sh linux package <stride-viz binary>   -> stride-app-linux-x86_64.tar.gz
#   package-viz.sh windows package <stride-viz.exe>    -> stride-app-windows-x86_64.zip
#   package-viz.sh linux prove                         -> the launcher seeds a fresh home
#   package-viz.sh windows prove
#
# Run from the repository root. A package holds the binary, the brand fonts,
# the splash's mark and the streak flame, and a launcher that seeds the fonts
# into ~/.stride/fonts and the images into ~/.stride/img, where the window
# reads them, then starts the window from the home directory with the
# athlete's directory as its first argument. `package` stages it under
# stage/stride-app, archives it with stride-app/ at the archive's root, and
# fails when the archive lacks the binary, the launcher, a face the window
# loads or either image. `prove` runs the staged
# launcher against an empty home, checks that every face and image arrives,
# then truncates one of each and checks that the next launch repairs them.
set -euo pipefail

faces="Quicksand-Medium.ttf JetBrainsMono-Regular.ttf"
images="stride-icon.png flame.png"

[ -f src/viz/main.roc ] || { echo "package-viz: run from the repository root" >&2; exit 2; }
os="${1:-}"
step="${2:-}"

stage_common() {
  rm -rf stage/stride-app
  mkdir -p stage/stride-app/fonts stage/stride-app/img
  cp assets/fonts/*.ttf assets/fonts/OFL-*.txt stage/stride-app/fonts/
  for f in $images; do cp "img/$f" stage/stride-app/img/; done
}

# every path the archive must hold, given the archiver's listing: each must
# end a line under stride-app/. 7z prints CRLF lines on windows, so carriage
# returns are dropped first; a listing in a variable keeps grep -q off a pipe
# that pipefail would fail on SIGPIPE; and each slash becomes a dot in the
# pattern, which matches the backslash 7z prints on windows as well
assert_listing() {
  listing="${1//$'\r'/}"; shift
  for p in "$@"; do
    grep -q "stride-app.${p//\//.}\$" <<<"$listing" || { echo "::error::the archive does not carry stride-app/$p"; exit 1; }
  done
}

# the archive paths every package carries besides its binary and launcher
carried() {
  for f in $faces; do echo "fonts/$f"; done
  for f in $images; do echo "img/$f"; done
}

# every face and image in the home given, byte for byte as shipped
check_seeded() {
  for f in $faces; do
    cmp -s "assets/fonts/$f" "$1/.stride/fonts/$f" || { echo "::error::launcher did not seed fonts/$f"; exit 1; }
  done
  for f in $images; do
    cmp -s "img/$f" "$1/.stride/img/$f" || { echo "::error::launcher did not seed img/$f"; exit 1; }
  done
}

linux_launcher() {
  cat <<'SH'
#!/bin/sh
# a desktop launch inherits a minimal PATH, and the window runs `stride`
# for the CP fit and `sh` for the zone offset. It also passes the athlete's
# directory, the window's read-write grant (a home resolved at launch cannot
# be written into the source the grant is declared in), and the home as the
# launch directory a capture's status row names its file under.
PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
export PATH
# the window reads ~/.stride/fonts; seed it from the copies shipped
# beside this script, replacing any that differ in size
here="$(cd "$(dirname "$0")" && pwd)"
log="$HOME/.stride/fonts-seed.log"
if [ -d "$here/fonts" ]; then
  if mkdir -p "$HOME/.stride/fonts" 2>/dev/null; then
    for f in "$here"/fonts/*.ttf; do
      [ -e "$f" ] || continue
      dst="$HOME/.stride/fonts/$(basename "$f")"
      if [ ! -e "$dst" ] || [ "$(wc -c < "$f")" != "$(wc -c < "$dst")" ]; then
        cp "$f" "$dst" 2>>"$log" || echo "$(date): could not write $dst" >> "$log"
      fi
    done
  else
    echo "$(date): could not create $HOME/.stride/fonts - the window will use its fallback font" >> "$log" 2>/dev/null || true
  fi
fi
# the splash's mark and the streak flame render from ~/.stride/img,
# seeded the same way
if [ -d "$here/img" ]; then
  if mkdir -p "$HOME/.stride/img" 2>/dev/null; then
    for f in "$here"/img/*.png; do
      [ -e "$f" ] || continue
      dst="$HOME/.stride/img/$(basename "$f")"
      if [ ! -e "$dst" ] || [ "$(wc -c < "$f")" != "$(wc -c < "$dst")" ]; then
        cp "$f" "$dst" 2>>"$log" || echo "$(date): could not write $dst" >> "$log"
      fi
    done
  else
    echo "$(date): could not create $HOME/.stride/img - the splash and the streak chip will show text alone" >> "$log" 2>/dev/null || true
  fi
fi
cd "$HOME"
exec "$here/stride-viz" "$HOME/.stride" "$HOME"
SH
}

# cmd misparses labels and goto with LF line endings, so the caller writes
# this with CRLF
windows_launcher() {
  cat <<'BAT'
@echo off
rem the window reads %USERPROFILE%\.stride\fonts and, for the splash's
rem mark and the streak flame, %USERPROFILE%\.stride\img; seed each from
rem the copies shipped beside this script, replacing any that differ in
rem size, then start the window from the home directory
set "here=%~dp0"
if not exist "%USERPROFILE%\.stride\fonts" mkdir "%USERPROFILE%\.stride\fonts" >nul 2>&1
for %%f in ("%here%fonts\*.ttf") do call :seed "%%~ff" fonts
if not exist "%USERPROFILE%\.stride\img" mkdir "%USERPROFILE%\.stride\img" >nul 2>&1
for %%f in ("%here%img\*.png") do call :seed "%%~ff" img
cd /d "%USERPROFILE%"
start "" "%here%stride-viz.exe" "%USERPROFILE%\.stride" "%USERPROFILE%"
exit /b 0
:seed
rem every %var% read below sits on its OWN line - cmd expands at
rem parse time per line, so no delayed expansion is needed; folding
rem these into a parenthesized block would break that property
set "src=%~1"
set "dst=%USERPROFILE%\.stride\%~2\%~nx1"
if not exist "%dst%" ( copy /y "%src%" "%dst%" >nul 2>&1 & goto :eof )
set "ssize=0"
set "dsize=0"
for %%A in ("%src%") do set "ssize=%%~zA"
for %%B in ("%dst%") do set "dsize=%%~zB"
if not "%ssize%"=="%dsize%" copy /y "%src%" "%dst%" >nul 2>&1
goto :eof
BAT
}

case "$os $step" in
  "linux package")
    bin="${3:?the linux binary to package}"
    test -s "$bin"
    stage_common
    cp "$bin" stage/stride-app/stride-viz
    linux_launcher > stage/stride-app/stride-app
    chmod +x stage/stride-app/stride-app stage/stride-app/stride-viz
    tar -C stage -czf stride-app-linux-x86_64.tar.gz stride-app
    # shellcheck disable=SC2046
    assert_listing "$(tar -tzf stride-app-linux-x86_64.tar.gz)" stride-viz stride-app $(carried)
    ;;
  "windows package")
    bin="${3:?the windows binary to package}"
    test -s "$bin"
    stage_common
    cp "$bin" stage/stride-app/stride-viz.exe
    windows_launcher | awk '{ printf "%s\r\n", $0 }' > stage/stride-app/stride-app.bat
    rm -f stride-app-windows-x86_64.zip
    7z a -bso0 stride-app-windows-x86_64.zip ./stage/stride-app
    # shellcheck disable=SC2046
    assert_listing "$(7z l stride-app-windows-x86_64.zip)" stride-viz.exe stride-app.bat $(carried)
    ;;
  "linux prove")
    fake="$(mktemp -d)"
    HOME="$fake" ./stage/stride-app/stride-app >/dev/null 2>&1 &
    pid=$!
    sleep 3
    kill $pid 2>/dev/null || true
    check_seeded "$fake"
    printf 'x' > "$fake/.stride/fonts/Quicksand-Medium.ttf"
    printf 'x' > "$fake/.stride/img/flame.png"
    HOME="$fake" ./stage/stride-app/stride-app >/dev/null 2>&1 &
    pid=$!
    sleep 3
    kill $pid 2>/dev/null || true
    check_seeded "$fake"
    rm -rf "$fake"
    ;;
  "windows prove")
    fake="$(mktemp -d)"
    fakewin="$(cygpath -w "$fake")"
    bat="$(cygpath -w "$PWD/stage/stride-app/stride-app.bat")"
    USERPROFILE="$fakewin" cmd //C "$bat" || true
    sleep 3
    taskkill //IM stride-viz.exe //F 2>/dev/null || true
    check_seeded "$fake"
    printf 'x' > "$fake/.stride/fonts/Quicksand-Medium.ttf"
    printf 'x' > "$fake/.stride/img/flame.png"
    USERPROFILE="$fakewin" cmd //C "$bat" || true
    sleep 3
    taskkill //IM stride-viz.exe //F 2>/dev/null || true
    check_seeded "$fake"
    rm -rf "$fake"
    ;;
  *)
    echo "usage: package-viz.sh linux|windows package <binary> | linux|windows prove" >&2
    exit 2
    ;;
esac
echo "package-viz: $os $step ok"

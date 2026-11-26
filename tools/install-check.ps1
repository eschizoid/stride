# Proves install.ps1, the one-line installer for Windows. The installs run in
# fake profiles (LOCALAPPDATA, APPDATA and USERPROFILE point into a scratch
# folder); the user's PATH lives in the registry, which no fake profile
# covers, so it is saved first and restored when the check ends.
#
#   install-check.ps1 static                         any OS with PowerShell 7
#   install-check.ps1 release <older tag> [<shell>]  Windows, the GitHub releases
#   install-check.ps1 local <folder> [<shell>]       Windows, packages built from this checkout
#
# <shell> is the PowerShell that runs install.ps1 and every new shell the
# checks open: powershell (Windows PowerShell, the default, which every
# Windows has) or pwsh.
#
# `static` checks that install.ps1 is ASCII and is one `& { ... }` statement
# whose block defines functions and ends by calling Install-Stride, and that
# it and install.sh ask the app question in the same words and name
# `stride setup` as the next step; then parses the file cut off after every
# byte and checks that each cut parses to no statement or fails to parse, so
# a cut-off download runs nothing. It then runs the installer's functions on
# local files: a download that fails its checksum or is not listed is
# refused, an installed tree is replaced in place and loses the files the new
# one lacks, and only the files the installer moved aside are cleared.
#
# `release` runs install.ps1 cut off at every line, as `irm | iex` would run
# a cut-off download, and checks that no cut writes an install or changes the
# user's PATH, while the whole file in the same profile installs; installs
# the latest release with STRIDE_INSTALL_APP unset and no console, and checks
# that it ends by naming `stride setup`, that stride.exe lands in
# %LOCALAPPDATA%\Programs\stride\bin, that the user's PATH names that folder
# once, that a new shell reading its PATH from the registry runs it, and
# that no app arrives; checks that a folder named
# stride.exe stops the install untouched; then installs the older tag with
# the app into STRIDE_INSTALL_DIR, checks that an app failing its checksum
# leaves the older command and app in place, holds the command and the
# window open, installs the latest over them, and checks that both are
# replaced while running, that the athlete's directory is kept, that the
# files moved aside are cleared by the next install, and that no installed
# file carries the Mark of the Web.
#
# `local` takes a folder holding this checkout's stride-cli-windows-x86_64.exe
# and stride-app-windows-x86_64.zip, writes its SHA256SUMS.txt, installs the
# latest release with the app and then the folder over it through
# STRIDE_DOWNLOAD_BASE, twice, and checks that stride.exe and the app's own
# bin\stride.exe are the folder's command byte for byte, that the Start-menu
# shortcut is written and kept, that the user's PATH names each folder once,
# that a new shell runs the folder's command, that the athlete's directory
# survives each update, and that no installed file carries the Mark of the
# Web.
#
# Run from the repository root. `release` and `local` read the latest
# release from GitHub, so both need the network.
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Mode,
  [Parameter(Position = 1)][string]$Arg,
  [Parameter(Position = 2)][ValidateSet('powershell', 'pwsh')][string]$Shell = 'powershell'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not (Test-Path -LiteralPath 'install.ps1')) { Write-Host 'install-check: run from the repository root'; exit 2 }
$here = (Get-Location).Path
$installer = Join-Path $here 'install.ps1'
# under the runner's own temporary folder when there is one: the system temp
# folder is often named by its 8.3 short form, which the paths a shell
# reports in their long form would not match
$tmpRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$scratch = Join-Path $tmpRoot ('install-check-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null

function Fail([string]$Message) { throw "install-check: $Message" }

# ---- static -------------------------------------------------------------

# the statements a text holds at its top level, or $null when it does not parse
function Get-TopStatements([string]$Text) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { return $null }
  , @($ast.EndBlock.Statements)
}

function Test-Static {
  $text = [IO.File]::ReadAllText($installer)
  if ($text -match '[^\x00-\x7F]') { Fail 'install.ps1 holds a non-ASCII character, which Windows PowerShell reads from a file without a byte-order mark as another code page' }
  $whole = Get-TopStatements $text
  if ($null -eq $whole) { Fail 'install.ps1 does not parse' }

  # the two one-line installers ask the app question in the same words, Enter
  # answering yes, and end by naming `stride setup`
  $sh = [IO.File]::ReadAllText((Join-Path $here 'install.sh'))
  foreach ($pair in @(@('install.ps1', $text), @('install.sh', $sh))) {
    if ($pair[1] -notmatch 'Also install the desktop app into \S+\? \[Y/n\]') { Fail "$($pair[0]) does not ask 'Also install the desktop app into ...? [Y/n]'" }
    if (-not $pair[1].Contains('next: run ')) { Fail "$($pair[0]) names no next step" }
  }
  if (-not $text.Contains("Write-Host 'next: run ``stride setup`` ")) { Fail 'install.ps1 does not end by naming stride setup' }
  Write-Host 'install-check: both one-line installers ask the app question alike and name stride setup next'

  # every cut short of the file's last statement-ending character parses
  # to no statement or fails to parse, and either way runs nothing
  $end = $text.TrimEnd().Length
  $n = 0
  for ($i = 1; $i -lt $end; $i++) {
    $st = Get-TopStatements $text.Substring(0, $i)
    if ($null -eq $st) { continue }
    if ($st.Count -gt 0) { Fail "install.ps1 cut after $i bytes runs '$($st[0].Extent.Text)'" }
    $n++
  }
  Write-Host "install-check: install.ps1 cut after each of its first $($end - 1) bytes runs nothing ($n of the cuts parse, to no statement)"

  # which holds because the whole file is one statement, `& { ... }`, run in
  # a scope of its own, whose block defines functions and ends by calling
  # Install-Stride
  $block = $null
  if ($whole.Count -eq 1 -and $whole[0] -is [Management.Automation.Language.PipelineAst] -and $whole[0].PipelineElements.Count -eq 1) {
    $c = $whole[0].PipelineElements[0]
    if ($c -is [Management.Automation.Language.CommandAst] -and $c.InvocationOperator -eq 'Ampersand' -and $c.CommandElements.Count -eq 1 -and
      $c.CommandElements[0] -is [Management.Automation.Language.ScriptBlockExpressionAst]) { $block = $c.CommandElements[0].ScriptBlock }
  }
  if ($null -eq $block) { Fail 'install.ps1 is not one `& { ... }` statement' }
  $body = @($block.EndBlock.Statements)
  $last = $body[$body.Count - 1]
  if ($last.Extent.Text -ne 'Install-Stride') { Fail "the block's last statement is '$($last.Extent.Text)', not the call Install-Stride" }
  foreach ($s in $body[0..($body.Count - 2)]) {
    if ($s -isnot [Management.Automation.Language.FunctionDefinitionAst]) { Fail "the block runs '$($s.Extent.Text)' before its last statement" }
  }

  # the installer's functions, defined here without the call that runs them
  foreach ($s in $body[0..($body.Count - 2)]) { . ([scriptblock]::Create($s.Extent.Text)) }

  $d = Join-Path $scratch 'static'
  $src = Join-Path $d 'release'
  New-Item -ItemType Directory -Force -Path $src | Out-Null
  [IO.File]::WriteAllText((Join-Path $src 'good'), "good`n")
  [IO.File]::WriteAllText((Join-Path $src 'bad'), "bad`n")
  $goodSum = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $src 'good')).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText((Join-Path $src 'SHA256SUMS.txt'), "$goodSum  good`n$('0' * 64) *bad`n")
  $base = [Uri]::new((Join-Path $src '')).AbsoluteUri.TrimEnd('/')
  $sums = Read-StrideSums (Join-Path $src 'SHA256SUMS.txt')
  if ($sums['good'] -ne $goodSum -or $sums['bad'] -ne ('0' * 64)) { Fail 'Read-StrideSums does not read both forms of a SHA256SUMS.txt line' }
  $dl = Join-Path $d 'dl'
  New-Item -ItemType Directory -Force -Path $dl | Out-Null
  $got = Get-StrideVerified $base $sums 'good' $dl
  if ([IO.File]::ReadAllText($got) -ne "good`n") { Fail 'Get-StrideVerified did not fetch a listed asset whose checksum matches' }
  foreach ($case in @(@('bad', 'failed its checksum'), @('absent', 'is not listed'))) {
    $msg = ''
    try { Get-StrideVerified $base $sums $case[0] $dl | Out-Null } catch { $msg = $_.Exception.Message }
    if ($msg -notlike "*$($case[1])*") { Fail "Get-StrideVerified took the asset '$($case[0])' (said '$msg')" }
  }

  # a tree installed over an older one: replaced file by file, the folder
  # kept, a file the new tree lacks gone, a file moved aside left for the
  # sweep, and the sweep clearing only what the installer moved aside
  $old = Join-Path $d 'app'
  New-Item -ItemType Directory -Force -Path (Join-Path $old 'bin') | Out-Null
  [IO.File]::WriteAllText(([IO.Path]::Combine($old, 'bin', 'stride.exe')), 'old')
  [IO.File]::WriteAllText((Join-Path $old 'gone.txt'), 'old')
  $new = Join-Path $d 'new'
  New-Item -ItemType Directory -Force -Path (Join-Path $new 'bin') | Out-Null
  [IO.File]::WriteAllText(([IO.Path]::Combine($new, 'bin', 'stride.exe')), 'new')
  [IO.File]::WriteAllText((Join-Path $new 'launch.bat'), 'new')
  $folder = (Get-Item -LiteralPath $old).CreationTimeUtc
  Install-StrideTree $new $old
  if ([IO.File]::ReadAllText(([IO.Path]::Combine($old, 'bin', 'stride.exe'))) -ne 'new') { Fail 'Install-StrideTree did not replace bin\stride.exe' }
  if ([IO.File]::ReadAllText((Join-Path $old 'launch.bat')) -ne 'new') { Fail 'Install-StrideTree did not add launch.bat' }
  if (Test-Path -LiteralPath (Join-Path $old 'gone.txt')) { Fail 'Install-StrideTree kept a file the new tree lacks' }
  if ((Get-Item -LiteralPath $old).CreationTimeUtc -ne $folder) { Fail 'Install-StrideTree replaced the folder itself' }
  $left = @(Get-ChildItem -LiteralPath $old -Recurse -File -Force | Where-Object { $_.Name -notin 'stride.exe', 'launch.bat' })
  if ($left.Count -ne 0) { Fail "Install-StrideTree left $($left.Name -join ', ') behind" }
  $shared = Join-Path $d 'shared'
  New-Item -ItemType Directory -Force -Path (Join-Path $shared 'sub') | Out-Null
  [IO.File]::WriteAllText((Join-Path $shared 'theirs.old'), 'x')
  [IO.File]::WriteAllText((Join-Path $shared 'stride.exe.0.stride-old'), 'x')
  [IO.File]::WriteAllText(([IO.Path]::Combine($shared, 'sub', 'a.0.stride-old')), 'x')
  Clear-StrideOld $shared
  if (Test-Path -LiteralPath (Join-Path $shared 'stride.exe.0.stride-old')) { Fail 'Clear-StrideOld kept a file the installer moved aside' }
  if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($shared, 'sub', 'a.0.stride-old')))) { Fail 'Clear-StrideOld without -Recurse went beneath the folder' }
  if (-not (Test-Path -LiteralPath (Join-Path $shared 'theirs.old'))) { Fail 'Clear-StrideOld removed a file the installer never moved aside' }
  Clear-StrideOld $shared -Recurse
  if (Test-Path -LiteralPath ([IO.Path]::Combine($shared, 'sub', 'a.0.stride-old'))) { Fail 'Clear-StrideOld -Recurse kept a file beneath the folder' }
  Write-Host 'install-check: a download failing its checksum or unlisted is refused, and a tree is replaced in place'
}

# ---- Windows ------------------------------------------------------------

# the user's PATH exactly as the registry stores it, and its kind, or $null
function Get-UserPathRaw {
  $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
  try {
    if ($null -eq $k -or $null -eq $k.GetValue('Path')) { return $null }
    @{ Value = [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind = $k.GetValueKind('Path') }
  } finally { if ($k) { $k.Close() } }
}

function Set-UserPathRaw($Saved) {
  $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
  try {
    if ($null -eq $Saved) { $k.DeleteValue('Path', $false) } else { $k.SetValue('Path', $Saved.Value, $Saved.Kind) }
  } finally { $k.Close() }
}

# the user's PATH entries, expanded, without trailing backslashes
function Get-UserPathEntries {
  $raw = Get-UserPathRaw
  if ($null -eq $raw) { return @() }
  @($raw.Value -split ';' | Where-Object { $_ -ne '' } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') })
}

# a new fake profile: its folder, and the environment an install reads
function New-Profile([string]$Name) {
  $p = Join-Path $scratch $Name
  New-Item -ItemType Directory -Path $p | Out-Null
  @{
    Dir = $p
    Env = @{
      USERPROFILE = $p
      LOCALAPPDATA = (Join-Path $p 'AppData\Local')
      APPDATA = (Join-Path $p 'AppData\Roaming')
    }
  }
}

# runs a program with the given arguments and environment, stdin closed,
# for at most ten minutes; returns its exit code and everything it printed
function Invoke-Child([string]$File, [string]$Arguments, [hashtable]$Vars) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $File
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  foreach ($v in @($psi.EnvironmentVariables.Keys)) { if ($v -like 'STRIDE_*') { $psi.EnvironmentVariables.Remove($v) } }
  foreach ($v in $Vars.Keys) { $psi.EnvironmentVariables[$v] = [string]$Vars[$v] }
  $p = [Diagnostics.Process]::Start($psi)
  $p.StandardInput.Close()
  $out = $p.StandardOutput.ReadToEndAsync()
  $err = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(600000)) { $p.Kill(); Fail "$File $Arguments ran past ten minutes" }
  $p.WaitForExit()
  @{ Code = $p.ExitCode; Out = ($out.Result + $err.Result) }
}

# runs a PowerShell script text in a new shell
function Invoke-Script([string]$Script, [hashtable]$Vars) {
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
  Invoke-Child $shell "-NoProfile -NonInteractive -EncodedCommand $enc" $Vars
}

# runs an installer file ($Path) in a profile the way `irm ... | iex` runs a
# download: its whole text handed to Invoke-Expression
function Invoke-Installer([string]$Path, $Profile, [hashtable]$Vars) {
  $all = @{}
  foreach ($k in $Profile.Env.Keys) { $all[$k] = $Profile.Env[$k] }
  foreach ($k in $Vars.Keys) { $all[$k] = $Vars[$k] }
  $all['STRIDE_CHECK_FILE'] = $Path
  Invoke-Script 'Invoke-Expression ([IO.File]::ReadAllText($env:STRIDE_CHECK_FILE))' $all
}

function Install-Ok($Profile, [hashtable]$Vars) {
  $r = Invoke-Installer $installer $Profile $Vars
  Write-Host $r.Out
  if ($r.Code -ne 0) { Fail "install.ps1 failed (exit $($r.Code))" }
}

# every file in a profile an install wrote, by its path under the profile:
# what lies under Programs\stride, the athlete's directory, and any shortcut
function Get-Installed($Profile) {
  $d = $Profile.Dir
  @(Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.FullName.Substring($d.Length + 1) } |
      Where-Object { $_ -like 'AppData\Local\Programs\stride*' -or $_ -like '.stride*' -or $_ -like '*Stride.lnk' })
}

# the first stride a new shell runs, reading its PATH from the registry as a
# new terminal does, and what it says to --version
function Get-FreshStride {
  $r = Invoke-Script '$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User"); $c = @(Get-Command stride -CommandType Application -ErrorAction Stop)[0]; $c.Source; & $c.Source --version' @{}
  if ($r.Code -ne 0) { Fail "a new shell cannot run stride: $($r.Out)" }
  $lines = @($r.Out -split "`r?`n" | Where-Object { $_ -ne '' })
  @{ Path = $lines[0]; Version = $lines[1] }
}

# a profile's special folder, resolved as a process in that profile does
function Get-ProfileFolder($Profile, [string]$Name) {
  $r = Invoke-Script "[Environment]::GetFolderPath('$Name')" $Profile.Env
  $r.Out.Trim()
}

# every file under the paths given that carries the Mark of the Web, the
# Zone.Identifier stream a browser download carries; the stream is planted on
# a scratch file first, so a listing that cannot see it fails instead of
# reading as clean
function Get-Marked([string[]]$Paths) {
  $probe = Join-Path $scratch 'motw-probe'
  [IO.File]::WriteAllText($probe, 'x')
  Set-Content -LiteralPath $probe -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
  $find = { param($f) $null -ne (Get-Item -LiteralPath $f -Stream Zone.Identifier -ErrorAction SilentlyContinue) }
  if (-not (& $find $probe)) { Fail "the Mark of the Web probe cannot see the stream planted on $probe" }
  @(foreach ($p in $Paths) {
      Get-ChildItem -LiteralPath $p -Recurse -Force -File | Where-Object { & $find $_.FullName } | ForEach-Object { $_.FullName }
    })
}

function Assert-NoMark([string[]]$Paths) {
  $m = Get-Marked $Paths
  if ($m.Count -gt 0) { Fail "the installer left the Mark of the Web on: $($m -join ', ')" }
  Write-Host 'install-check: no installed file carries the Mark of the Web'
}

function Assert-PathOnce([string]$Dir) {
  $n = @(Get-UserPathEntries | Where-Object { $_ -eq $Dir.TrimEnd('\') }).Count
  if ($n -ne 1) { Fail "the user's PATH names $Dir $n times, not once" }
}

function Set-AthleteDir($Profile) {
  $s = Join-Path $Profile.Dir '.stride'
  New-Item -ItemType Directory -Force -Path (Join-Path $s 'fonts'), (Join-Path $s 'img') | Out-Null
  [IO.File]::WriteAllText((Join-Path $s 'db.sqlite'), 'athlete data')
  [IO.File]::WriteAllText((Join-Path $s 'fonts\Seeded.ttf'), 'font')
  [IO.File]::WriteAllText((Join-Path $s 'img\seeded.png'), 'image')
}

function Assert-AthleteDir($Profile) {
  $s = Join-Path $Profile.Dir '.stride'
  foreach ($kv in @(@('db.sqlite', 'athlete data'), @('fonts\Seeded.ttf', 'font'), @('img\seeded.png', 'image'))) {
    $f = Join-Path $s $kv[0]
    if (-not (Test-Path -LiteralPath $f) -or [IO.File]::ReadAllText($f) -ne $kv[1]) { Fail "an update changed the athlete's directory: $f" }
  }
}

function Get-Version([string]$Exe) { ((& $Exe --version) -join ' ').Trim() }

function Get-Sha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

function Get-LatestTag {
  $u = & curl.exe -fsSIL -o NUL -w '%{url_effective}' 'https://github.com/eschizoid/stride/releases/latest'
  if ($LASTEXITCODE -ne 0) { Fail 'could not read the latest release from GitHub' }
  ($u -replace '.*/tag/', '').Trim()
}

# starts a copy of ping.exe at $Path, the name of an installed program, so
# that an update meets that file in use, as it meets a running stride.exe
function Start-Holder([string]$Path) {
  Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $Path -Force
  Start-Process -FilePath $Path -ArgumentList '-n', '600', '127.0.0.1' -WindowStyle Hidden -PassThru
}

function Test-Release([string]$Older) {
  $latest = Get-LatestTag
  if (-not $latest -or $latest -eq $Older) { Fail "the latest release is '$latest', which is no update over $Older" }
  $before = Get-UserPathRaw

  # a download cut off at any line installs nothing and leaves the PATH
  # alone; the whole file, run the same way in the same profile, does both
  $lines = [IO.File]::ReadAllLines($installer)
  $cut = Join-Path $scratch 'cut.ps1'
  $prof = New-Profile 'cut'
  for ($i = 1; $i -lt $lines.Count; $i++) {
    [IO.File]::WriteAllText($cut, (($lines[0..($i - 1)]) -join "`r`n") + "`r`n")
    Invoke-Installer $cut $prof @{ STRIDE_INSTALL_APP = '0' } | Out-Null
    $w = Get-Installed $prof
    if ($w.Count -gt 0) { Fail "install.ps1 cut after $i lines wrote $($w -join ', ')" }
    $now = Get-UserPathRaw
    if ("$($now.Value)" -ne "$($before.Value)") { Fail "install.ps1 cut after $i lines changed the user's PATH" }
  }
  $r = Invoke-Installer $installer $prof @{ STRIDE_INSTALL_APP = '0' }
  if ($r.Code -ne 0 -or (Get-Installed $prof).Count -eq 0) { Fail "the whole install.ps1, run as each cut was, installed nothing: $($r.Out)" }
  Set-UserPathRaw $before
  Write-Host "install-check: install.ps1 cut at each of its $($lines.Count) lines installs nothing, and whole it installs"

  # the latest release, STRIDE_INSTALL_APP unset and no console: the
  # command alone, in its per-user folder, on the user's PATH
  $prof = New-Profile 'fresh'
  $r = Invoke-Installer $installer $prof @{}
  Write-Host $r.Out
  if ($r.Code -ne 0) { Fail "install.ps1 failed (exit $($r.Code))" }
  $last = @($r.Out.Trim() -split "`r?`n")[-1]
  if (-not $last.StartsWith('next: run `stride setup` ')) { Fail "install.ps1 did not end by naming stride setup; its last line was '$last'" }
  $bin = Join-Path $prof.Env.LOCALAPPDATA 'Programs\stride\bin'
  $exe = Join-Path $bin 'stride.exe'
  if (-not (Test-Path -LiteralPath $exe)) { Fail "no stride.exe at $exe" }
  $v = Get-Version $exe
  if ($v -ne "stride $($latest.TrimStart('v'))") { Fail "the installed command says '$v', not stride $($latest.TrimStart('v'))" }
  if (Test-Path -LiteralPath (Join-Path $prof.Env.LOCALAPPDATA 'Programs\stride\stride-app')) { Fail 'the app arrived without being asked for' }
  Assert-PathOnce $bin
  $fresh = Get-FreshStride
  if ($fresh.Path -ne $exe -or $fresh.Version -ne $v) { Fail "a new shell runs '$($fresh.Path)' saying '$($fresh.Version)', not $exe saying $v" }
  Assert-NoMark @($bin)
  Write-Host "install-check: the latest release installs $v into $bin, which a new shell runs by name"
  Set-UserPathRaw $before

  # a folder where stride.exe goes stops the install before it changes
  # anything
  $prof = New-Profile 'folder'
  $bin = Join-Path $prof.Env.LOCALAPPDATA 'Programs\stride\bin'
  New-Item -ItemType Directory -Force -Path (Join-Path $bin 'stride.exe') | Out-Null
  [IO.File]::WriteAllText((Join-Path $bin 'stride.exe\kept'), 'x')
  $r = Invoke-Installer $installer $prof @{ STRIDE_INSTALL_APP = '1' }
  if ($r.Code -eq 0) { Fail 'install.ps1 installed over the folder stride.exe' }
  if ($r.Out -notlike '*is a folder*') { Fail "install.ps1 did not say why it refused the folder stride.exe: $($r.Out)" }
  if (-not (Test-Path -LiteralPath (Join-Path $bin 'stride.exe\kept'))) { Fail 'install.ps1 changed the folder stride.exe it refused' }
  if (Test-Path -LiteralPath (Join-Path $prof.Env.LOCALAPPDATA 'Programs\stride\stride-app')) { Fail 'install.ps1 installed the app while refusing the folder stride.exe' }
  if ("$((Get-UserPathRaw).Value)" -ne "$($before.Value)") { Fail "install.ps1 changed the user's PATH while refusing the folder stride.exe" }
  Write-Host 'install-check: a folder at stride.exe stops the install, untouched'

  # the older release with the app into STRIDE_INSTALL_DIR, then the latest
  # over it while the command and the window are running
  $prof = New-Profile 'update'
  Set-AthleteDir $prof
  $tools = Join-Path $prof.Dir 'tools'
  $app = Join-Path $prof.Env.LOCALAPPDATA 'Programs\stride\stride-app'
  Install-Ok $prof @{ STRIDE_VERSION = $Older; STRIDE_INSTALL_APP = '1'; STRIDE_INSTALL_DIR = $tools }
  $exe = Join-Path $tools 'stride.exe'
  $v = Get-Version $exe
  if ($v -ne "stride $($Older.TrimStart('v'))") { Fail "$Older installed a command saying '$v'" }
  if (-not (Test-Path -LiteralPath (Join-Path $app 'stride-viz.exe'))) { Fail "$Older's app was not installed in $app" }
  [IO.File]::WriteAllText((Join-Path $app 'from-the-older-install'), 'x')

  # an app that fails its checksum stops the update before the command is
  # replaced, so the command and the app stay one release's
  $mirror = Join-Path $scratch 'mirror'
  New-Item -ItemType Directory -Path $mirror | Out-Null
  $cliName = 'stride-cli-windows-x86_64.exe'
  & curl.exe -fsSL -o (Join-Path $mirror $cliName) "https://github.com/eschizoid/stride/releases/latest/download/$cliName"
  if ($LASTEXITCODE -ne 0) {
    $cliName = 'stride-cli-windows-x86_64'
    & curl.exe -fsSL -o (Join-Path $mirror $cliName) "https://github.com/eschizoid/stride/releases/latest/download/$cliName"
    if ($LASTEXITCODE -ne 0) { Fail 'could not download the latest windows command' }
  }
  & curl.exe -fsSL -o (Join-Path $mirror 'stride-app-windows-x86_64.zip') 'https://github.com/eschizoid/stride/releases/latest/download/stride-app-windows-x86_64.zip'
  if ($LASTEXITCODE -ne 0) { Fail 'could not download the latest windows app' }
  [IO.File]::WriteAllText((Join-Path $mirror 'SHA256SUMS.txt'), "$(Get-Sha (Join-Path $mirror $cliName))  $cliName`n$('0' * 64)  stride-app-windows-x86_64.zip`n")
  $r = Invoke-Installer $installer $prof @{ STRIDE_INSTALL_APP = '1'; STRIDE_INSTALL_DIR = $tools; STRIDE_DOWNLOAD_BASE = [Uri]::new((Join-Path $mirror '')).AbsoluteUri.TrimEnd('/') }
  if ($r.Code -eq 0) { Fail 'install.ps1 installed an app that failed its checksum' }
  if ($r.Out -notlike '*stride-app-windows-x86_64.zip failed its checksum*') { Fail "install.ps1 did not refuse the app for its checksum: $($r.Out)" }
  $v = Get-Version $exe
  if ($v -ne "stride $($Older.TrimStart('v'))") { Fail "an app that failed its checksum still left the command saying '$v', not stride $($Older.TrimStart('v'))" }
  if (-not (Test-Path -LiteralPath (Join-Path $app 'from-the-older-install'))) { Fail 'an app that failed its checksum still replaced the older app' }
  Write-Host 'install-check: an app failing its checksum leaves the older command and app in place'
  $holders = @((Start-Holder $exe), (Start-Holder (Join-Path $app 'stride-viz.exe')))
  try {
    Install-Ok $prof @{ STRIDE_INSTALL_APP = '1'; STRIDE_INSTALL_DIR = $tools }
    $v = Get-Version $exe
    if ($v -ne "stride $($latest.TrimStart('v'))") { Fail "the update left a command saying '$v', not stride $($latest.TrimStart('v'))" }
    if ((Get-Item -LiteralPath (Join-Path $app 'stride-viz.exe')).Length -eq (Get-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE')).Length) { Fail 'the update did not replace the running stride-viz.exe' }
    if (Test-Path -LiteralPath (Join-Path $app 'from-the-older-install')) { Fail "the update kept a file the new app lacks in $app" }
    $held = @(Get-ChildItem -LiteralPath $tools, $app -Recurse -Force -File -Filter '*.stride-old')
    if ($held.Count -ne 2) { Fail "the update moved aside $($held.Count) running files, not 2: $($held.Name -join ', ')" }
  } finally {
    foreach ($h in $holders) { if (-not $h.HasExited) { $h.Kill(); $h.WaitForExit() } }
  }
  Assert-AthleteDir $prof
  Assert-PathOnce $tools
  # the next install clears what the last one moved aside, once nothing holds it
  Install-Ok $prof @{ STRIDE_INSTALL_APP = '1'; STRIDE_INSTALL_DIR = $tools }
  $held = @(Get-ChildItem -LiteralPath $tools, $app -Recurse -Force -File -Filter '*.stride-old')
  if ($held.Count -ne 0) { Fail "a later install left $($held.Name -join ', ')" }
  Assert-AthleteDir $prof
  Assert-PathOnce $tools
  Assert-NoMark @($tools, $app)
  Write-Host "install-check: $latest installs over $Older in place while both programs run, and the athlete's directory is kept"
}

function Test-Local([string]$Folder) {
  $src = (Resolve-Path -LiteralPath $Folder).Path
  $cli = Join-Path $src 'stride-cli-windows-x86_64.exe'
  $zip = Join-Path $src 'stride-app-windows-x86_64.zip'
  foreach ($f in $cli, $zip) { if (-not (Test-Path -LiteralPath $f)) { Fail "$src holds no $(Split-Path -Leaf $f)" } }
  $lines = foreach ($f in $cli, $zip) { "$(Get-Sha $f)  $(Split-Path -Leaf $f)" }
  [IO.File]::WriteAllText((Join-Path $src 'SHA256SUMS.txt'), (($lines -join "`n") + "`n"))
  $want = Get-Sha $cli
  $wantV = Get-Version $cli
  $base = [Uri]::new((Join-Path $src '')).AbsoluteUri.TrimEnd('/')

  $prof = New-Profile 'local'
  Set-AthleteDir $prof
  Install-Ok $prof @{ STRIDE_INSTALL_APP = '1' }
  $bin = Join-Path $prof.Env.LOCALAPPDATA 'Programs\stride\bin'
  $app = Join-Path $prof.Env.LOCALAPPDATA 'Programs\stride\stride-app'
  [IO.File]::WriteAllText((Join-Path $app 'from-the-older-install'), 'x')
  foreach ($round in 1, 2) {
    Install-Ok $prof @{ STRIDE_INSTALL_APP = '1'; STRIDE_DOWNLOAD_BASE = $base }
    if ((Get-Sha (Join-Path $bin 'stride.exe')) -ne $want) { Fail "round $round installed a stride.exe that is not $cli" }
    $own = Join-Path $app 'bin\stride.exe'
    if (-not (Test-Path -LiteralPath $own) -or (Get-Sha $own) -ne $want) { Fail "round $round installed an app whose bin\stride.exe is not $cli" }
    if (Test-Path -LiteralPath (Join-Path $app 'from-the-older-install')) { Fail "round $round kept a file the new app lacks" }
    $programs = Get-ProfileFolder $prof 'Programs'
    if (-not (Test-Path -LiteralPath (Join-Path $programs 'Stride.lnk'))) { Fail "round $round left no Start-menu shortcut in $programs" }
    Assert-PathOnce $bin
    Assert-PathOnce (Join-Path $app 'bin')
    $fresh = Get-FreshStride
    if ($fresh.Path -ne (Join-Path $bin 'stride.exe') -or $fresh.Version -ne $wantV) { Fail "round ${round}: a new shell runs '$($fresh.Path)' saying '$($fresh.Version)', not $bin\stride.exe saying $wantV" }
    Assert-AthleteDir $prof
    Assert-NoMark @($bin, $app)
    [IO.File]::WriteAllText((Join-Path $app 'from-the-older-install'), 'x')
  }
  Write-Host "install-check: this checkout's packages install over the latest release, and over themselves, in place"
}

$code = 0
$saved = $null
$onWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows
try {
  switch ($Mode) {
    'static' { Test-Static }
    'release' {
      if (-not $onWindows) { Fail 'release runs on Windows' }
      if (-not $Arg) { Fail 'release needs an older release tag to update from' }
      $saved = @{ Path = Get-UserPathRaw }
      Test-Release $Arg
    }
    'local' {
      if (-not $onWindows) { Fail 'local runs on Windows' }
      if (-not $Arg) { Fail 'local needs the folder holding the command and app package' }
      $saved = @{ Path = Get-UserPathRaw }
      Test-Local $Arg
    }
    default { Write-Host 'usage: install-check.ps1 static | release <older tag> | local <folder>'; $code = 2 }
  }
} catch {
  Write-Host "::error::$($_.Exception.Message)"
  Write-Host $_.ScriptStackTrace
  $code = 1
} finally {
  if ($saved) { Set-UserPathRaw $saved.Path }
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($scratch, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code

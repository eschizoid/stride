# Install the stride command line, and the desktop app if you want it, from a
# GitHub release on Windows. In PowerShell:
#
#   irm https://raw.githubusercontent.com/eschizoid/stride/main/install.ps1 | iex
#
# It needs no administrator rights. The command goes to
# %LOCALAPPDATA%\Programs\stride\bin, which is added to your user PATH, and
# the app to %LOCALAPPDATA%\Programs\stride\stride-app, whose install.cmd puts
# it in the Start menu and its own stride command on the PATH. Running this
# again installs the newer release over the old one in place, file by file;
# %USERPROFILE%\.stride and the shortcuts are kept. On macOS and Linux,
# install.sh in this repository does the same.
#
# Environment:
#   STRIDE_VERSION       a release tag such as v0.20.0 (default: the latest release)
#   STRIDE_INSTALL_DIR   where stride.exe goes (default: %LOCALAPPDATA%\Programs\stride\bin)
#   STRIDE_INSTALL_APP   1 installs the desktop app without asking, 0 skips it;
#                        unset asks when a console is attached
#   STRIDE_DOWNLOAD_BASE a folder holding a release's assets, as an https or
#                        file:// URL, read in place of the GitHub release
#
# Every download is checked against the release's SHA256SUMS.txt before
# anything is installed from it, so a checksum only vouches for what the same
# place serves. A file PowerShell downloads carries no Mark of the Web, so
# SmartScreen does not stop the app on its first start.
#
# Everything below is one script block, opened on the next line and closed
# and run on the last: a download cut off anywhere before that last line
# leaves the block unclosed, which PowerShell refuses to parse, so it runs
# nothing. The functions it defines also end with the block, leaving none
# behind in the session that ran it.
& {
  # copies one release asset to a local file
  function Get-StrideAsset([string]$Base, [string]$Name, [string]$Dest) {
    $url = $Base + '/' + $Name
    if ($Base -like 'file:*') {
      Copy-Item -LiteralPath ([Uri]$url).LocalPath -Destination $Dest
    } else {
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $Dest
    }
  }

  # SHA256SUMS.txt as a table from asset name to its lowercase hash
  function Read-StrideSums([string]$Path) {
    $sums = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
      $parts = $line.Trim() -split '\s+', 2
      if ($parts.Count -eq 2) { $sums[$parts[1].TrimStart('*')] = $parts[0].ToLowerInvariant() }
    }
    $sums
  }

  # downloads one asset into $Dir and returns its path, or throws when the
  # asset is unlisted, cannot be fetched or fails its checksum
  function Get-StrideVerified([string]$Base, [hashtable]$Sums, [string]$Name, [string]$Dir) {
    if (-not $Sums.ContainsKey($Name)) { throw "stride install: $Name is not listed in SHA256SUMS.txt" }
    $dest = Join-Path $Dir $Name
    try { Get-StrideAsset $Base $Name $dest } catch { throw "stride install: could not download $Base/$Name ($($_.Exception.Message))" }
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLowerInvariant()
    if ($got -ne $Sums[$Name]) { throw "stride install: $Name failed its checksum (expected $($Sums[$Name]), got $got)" }
    $dest
  }

  # Moves the file at $Path out of the way. Windows refuses to overwrite or
  # delete a program that is running but lets it be renamed, so the file is
  # renamed aside to a name ending .stride-old, then removed if nothing holds
  # it; one still held is removed by Clear-StrideOld on a later install.
  function Remove-StrideAside([string]$Path) {
    $old = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.stride-old'
    Move-Item -LiteralPath $Path -Destination $old -Force
    Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
  }

  # puts a new file at $Dest, the old one moved aside first
  function Install-StrideFile([string]$Source, [string]$Dest) {
    if (Test-Path -LiteralPath $Dest) { Remove-StrideAside $Dest }
    Move-Item -LiteralPath $Source -Destination $Dest -Force
  }

  # removes the files Remove-StrideAside left in a folder ($Recurse: and
  # beneath it) that nothing holds any more; no other file is touched, so a
  # STRIDE_INSTALL_DIR shared with other programs keeps theirs
  function Clear-StrideOld([string]$Dir, [switch]$Recurse) {
    if (Test-Path -LiteralPath $Dir) {
      Get-ChildItem -LiteralPath $Dir -Recurse:$Recurse -File -Force -Filter '*.stride-old' |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
  }

  # Installs every file under $Source at the same place under $Dest through
  # Install-StrideFile, and moves aside every file there that the new tree no
  # longer holds, so the folder ends up holding exactly the new package while
  # the folder itself, which the shortcuts and the PATH name, stays.
  function Install-StrideTree([string]$Source, [string]$Dest) {
    $src = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\', '/')
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $dst = (Get-Item -LiteralPath $Dest).FullName.TrimEnd('\', '/')
    $keep = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -Force)) {
      $rel = $f.FullName.Substring($src.Length + 1)
      $keep[$rel] = $true
      $to = Join-Path $dst $rel
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
      Install-StrideFile $f.FullName $to
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $dst -Recurse -File -Force)) {
      $rel = $f.FullName.Substring($dst.Length + 1)
      if ($rel -like '*.stride-old' -or $keep.ContainsKey($rel)) { continue }
      Remove-StrideAside $f.FullName
    }
  }

  # Appends $Dir to the user's PATH unless an entry already names it, in any
  # case and with or without a trailing backslash, and says which. The value is
  # read and written in the registry as stored, so an entry written with a
  # %VARIABLE% keeps it. Setting and clearing a user variable broadcasts the
  # change, so a terminal opened from then on sees it; one already open does
  # not.
  function Add-StrideUserPath([string]$Dir) {
    $Dir = $Dir.TrimEnd('\')
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
      $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      $have = @($raw -split ';' | Where-Object { $_ -ne '' } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') })
      if ($have -contains $Dir) { return $false }
      $kept = $raw.TrimEnd(';')
      if ($kept) { $kept = $kept + ';' }
      $key.SetValue('Path', $kept + $Dir, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
      $key.Close()
    }
    [Environment]::SetEnvironmentVariable('STRIDE_PATH_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('STRIDE_PATH_REFRESH', $null, 'User')
    $true
  }

  # the first stride a new terminal runs: the machine PATH, then the user's,
  # each folder tried with every extension PATHEXT names
  function Find-StrideOnNewPath {
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $exts = @(([string]$env:PATHEXT) -split ';' | Where-Object { $_ -ne '' })
    if (-not $exts) { $exts = @('.COM', '.EXE', '.BAT', '.CMD') }
    foreach ($d in ($path -split ';' | Where-Object { $_ -ne '' })) {
      foreach ($e in $exts) {
        $p = Join-Path $d ('stride' + $e)
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
      }
    }
    $null
  }

  function Install-Stride {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $repo = 'eschizoid/stride'
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
      throw 'stride install: this installer is for Windows; on macOS and Linux run install.sh'
    }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'stride install: there is no release build for 32-bit Windows' }
    # GitHub serves TLS 1.2 and up, which Windows PowerShell does not always offer by default
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $version = if ($env:STRIDE_VERSION) { $env:STRIDE_VERSION } else { 'latest' }
    $root = Join-Path $env:LOCALAPPDATA 'Programs\stride'
    $dir = if ($env:STRIDE_INSTALL_DIR) { $env:STRIDE_INSTALL_DIR } else { Join-Path $root 'bin' }
    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($dir)
    $appdir = Join-Path $root 'stride-app'
    if ($env:STRIDE_DOWNLOAD_BASE) {
      $base = $env:STRIDE_DOWNLOAD_BASE.TrimEnd('/')
      $version = "from $base"
    } elseif ($version -eq 'latest') {
      $base = "https://github.com/$repo/releases/latest/download"
    } elseif ($version -like 'v*') {
      $base = "https://github.com/$repo/releases/download/$version"
    } else {
      $base = "https://github.com/$repo/releases/download/v$version"
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('stride-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
      try { Get-StrideAsset $base 'SHA256SUMS.txt' (Join-Path $tmp 'SHA256SUMS.txt') } catch { throw "stride install: could not download $base/SHA256SUMS.txt ($($_.Exception.Message))" }
      $sums = Read-StrideSums (Join-Path $tmp 'SHA256SUMS.txt')

      # releases before the command was published with its extension name it
      # without one
      $asset = 'stride-cli-windows-x86_64.exe'
      if (-not $sums.ContainsKey($asset)) { $asset = 'stride-cli-windows-x86_64' }
      Write-Host "downloading $asset ($version)"
      $cli = Get-StrideVerified $base $sums $asset $tmp
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      Clear-StrideOld $dir
      Install-StrideFile $cli (Join-Path $dir 'stride.exe')
      $exe = Join-Path $dir 'stride.exe'
      $said = 'version unknown'
      try { $said = (& $exe --version) -join ' ' } catch {}
      Write-Host "installed $exe ($said)"

      if (Add-StrideUserPath $dir) { Write-Host "added $dir to your PATH" }
      if (-not (@($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -contains $dir.TrimEnd('\'))) {
        $env:Path = $env:Path.TrimEnd(';') + ';' + $dir
      }
      $first = Find-StrideOnNewPath
      if ($first -and $first -ne $exe) {
        Write-Host ''
        Write-Host "note: a new terminal runs $first before $exe, because its folder comes earlier on the PATH; remove that copy to run this one"
      }

      # asked only on a console; a host that cannot prompt, such as one
      # started -NonInteractive, refuses Read-Host, and that is a no
      $want = $env:STRIDE_INSTALL_APP
      if (-not $want) {
        $want = '0'
        if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
          $answer = ''
          try { $answer = Read-Host "Also install the desktop app into $appdir? [y/N]" } catch {}
          if ($answer -match '^(y|yes)$') { $want = '1' }
        }
      }
      if ($want -eq '1') {
        $zip = Get-StrideVerified $base $sums 'stride-app-windows-x86_64.zip' $tmp
        $unpacked = Join-Path $tmp 'app'
        Expand-Archive -LiteralPath $zip -DestinationPath $unpacked
        $new = Join-Path $unpacked 'stride-app'
        if (-not (Test-Path -LiteralPath (Join-Path $new 'stride-app.bat'))) { throw 'stride install: the app archive holds no stride-app\stride-app.bat' }
        Clear-StrideOld $appdir -Recurse
        Install-StrideTree $new $appdir
        Write-Host "installed $appdir"
        $step = Join-Path $appdir 'install.cmd'
        if (Test-Path -LiteralPath $step) {
          # cmd keeps the quotes around a path after call, so any & or
          # parenthesis in it survives; STRIDE_APP_START=0 keeps the step from
          # starting the window
          $psi = New-Object Diagnostics.ProcessStartInfo
          $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
          $psi.Arguments = '/d /c call "' + $step + '"'
          $psi.UseShellExecute = $false
          $psi.EnvironmentVariables['STRIDE_APP_START'] = '0'
          $p = [Diagnostics.Process]::Start($psi)
          $p.WaitForExit()
          if ($p.ExitCode -ne 0) { throw "stride install: $step failed (exit $($p.ExitCode))" }
        } else {
          Write-Host "note: this release's app has no install step; start it with $appdir\stride-app.bat"
        }
      }
    } finally {
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host 'next: run "stride setup" to connect Strava, set your timezone and heart-rate zones, and pull your history. This terminal runs it now; any other terminal already open needs reopening first.'
  }

  Install-Stride
}

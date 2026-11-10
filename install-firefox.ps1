# install-firefox.ps1 - Windows version of install-firefox
#
# Installs a user.js (Betterfox by default), optionally a userChrome.css and a
# userContent.css into a Firefox profile. Each file can come from a raw link or
# a local file path, and each step can be skipped with (n).
#
# Run it with:
#   powershell -ExecutionPolicy Bypass -File .\install-firefox.ps1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes downloads very slow on Windows PowerShell 5.1

# GitHub needs TLS 1.2, which Windows PowerShell 5.1 does not always enable by default
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$BaseDir = Join-Path (Join-Path $env:APPDATA 'Mozilla') 'Firefox'
$IniFile = Join-Path $BaseDir 'profiles.ini'

# Helper: fetch SOURCE (a URL or a local file path) into DESTINATION.
# Local paths may start with ~ or contain %VARS%, and may be wrapped in quotes.
# Returns $true on success and $false on failure.
function Get-FileFromSource {
    param([string]$Source, [string]$Destination)

    $src = $Source.Trim()
    if ($src.Length -ge 2 -and (($src.StartsWith('"') -and $src.EndsWith('"')) -or ($src.StartsWith("'") -and $src.EndsWith("'")))) {
        $src = $src.Substring(1, $src.Length - 2)
    }

    if ($src -match '^https?://') {
        Write-Host "Downloading from: $src ..."
        try {
            Invoke-WebRequest -Uri $src -OutFile $Destination -UseBasicParsing | Out-Null
            return $true
        } catch {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            Write-Host "Error: download failed. Please verify the URL."
            return $false
        }
    }

    # Expand a leading ~ to the home folder, and any %VARS%
    if ($src -eq '~' -or $src -match '^~[\\/]') {
        $src = Join-Path $HOME $src.Substring(1).TrimStart('\', '/')
    }
    $src = [Environment]::ExpandEnvironmentVariables($src)

    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Write-Host "Error: '$src' does not exist or is not a file."
        return $false
    }

    Write-Host "Copying from: $src ..."
    try {
        Copy-Item -LiteralPath $src -Destination $Destination -Force
        return $true
    } catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        Write-Host "Error: could not copy the file."
        return $false
    }
}

# Helper: Firefox ignores userChrome.css and userContent.css unless this pref is on.
# Called by both CSS install steps so either file alone is enough to enable it.
# Creates user.js if the user declined the user.js step, so the pref still lands somewhere.
function Enable-LegacyStylesheets {
    param([string]$UserJsPath)

    $prefPattern = '^\s*user_pref\("toolkit\.legacyUserProfileCustomizations\.stylesheets"'
    $prefText = 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # Already enabled - say nothing (keeps re-runs quiet)
    if ((Test-Path -LiteralPath $UserJsPath) -and (Select-String -LiteralPath $UserJsPath -Pattern $prefPattern -Quiet)) {
        return
    }

    if (Test-Path -LiteralPath $UserJsPath) {
        $appendText = "`r`n// Enable userChrome.css / userContent.css`r`n$prefText`r`n"
        [IO.File]::AppendAllText($UserJsPath, $appendText, $utf8NoBom)
        Write-Host "Enabled userChrome.css / userContent.css support in user.js"
    } else {
        $createText = "// Created by the install script: enable userChrome.css / userContent.css`r`n$prefText`r`n"
        [IO.File]::WriteAllText($UserJsPath, $createText, $utf8NoBom)
        Write-Host "Created user.js containing only the userChrome.css / userContent.css pref"
    }
}

# Helper: find firefox.exe when Firefox is not already running
function Find-Firefox {
    $cmd = Get-Command firefox -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe'),
        (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\firefox.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }

    foreach ($hive in 'HKLM:', 'HKCU:') {
        $key = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe"
        $val = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).'(default)'
        if ($val -and (Test-Path -LiteralPath $val)) { return $val }
    }
    return $null
}

function Start-FirefoxProfile {
    param([string]$Exe, [string]$ProfileName)
    if (-not $Exe) {
        Write-Host "Could not find firefox.exe. Please start Firefox manually."
        return
    }
    Start-Process -FilePath $Exe -ArgumentList @('-P', "`"$ProfileName`"")
}

if (-not (Test-Path -LiteralPath $IniFile)) {
    Write-Host "Error: could not find $IniFile"
    Write-Host "Is Firefox installed, and has it been opened at least once?"
    exit 1
}

# 1. Parse profiles.ini into sections
$sections = [ordered]@{}
$current = $null
foreach ($line in Get-Content -LiteralPath $IniFile) {
    $line = $line.Trim()
    if ($line -match '^\[(.+)\]$') {
        $current = $Matches[1]
        $sections[$current] = @{}
        continue
    }
    if ($current -and $line -match '^([^=;#][^=]*)=(.*)$') {
        $sections[$current][$Matches[1].Trim()] = $Matches[2].Trim()
    }
}

# 2. Find the current active installation default path
$ActivePath = $null
foreach ($name in $sections.Keys) {
    if ($name -like 'Install*' -and $sections[$name].ContainsKey('Default')) {
        $ActivePath = $sections[$name]['Default']
        break
    }
}

# 3. Collect profiles (name, path as written in the ini, absolute folder)
$Profiles = @()
foreach ($name in $sections.Keys) {
    if ($name -match '^Profile\d+$' -and $sections[$name].ContainsKey('Name') -and $sections[$name].ContainsKey('Path')) {
        $p = $sections[$name]
        $relPath = $p['Path'] -replace '/', [IO.Path]::DirectorySeparatorChar
        if ($p['IsRelative'] -eq '0') { $dir = $relPath } else { $dir = Join-Path $BaseDir $relPath }
        $Profiles += [pscustomobject]@{ Name = $p['Name']; IniPath = $p['Path']; Dir = $dir }
    }
}

if ($Profiles.Count -eq 0) {
    Write-Host "Error: no Firefox profiles found in $IniFile"
    exit 1
}

# 4. Display options (marking default)
Write-Host "Select a Firefox profile:"
for ($i = 0; $i -lt $Profiles.Count; $i++) {
    $label = $Profiles[$i].Name
    if ($Profiles[$i].IniPath -eq $ActivePath) { $label += ' [default]' }
    Write-Host ("{0}) {1}" -f ($i + 1), $label)
}

while ($true) {
    $choice = Read-Host "Please enter your choice (1-$($Profiles.Count))"
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $Profiles.Count) {
        $Selected = $Profiles[[int]$choice - 1]
        break
    }
    Write-Host "Invalid selection. Please try again."
}

$SelectedProfile = $Selected.Name
$ProfileDir = $Selected.Dir
$ChromeDir = Join-Path $ProfileDir 'chrome'
$UserJsPath = Join-Path $ProfileDir 'user.js'

if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) {
    Write-Host "Error: profile folder not found: $ProfileDir"
    exit 1
}

Write-Host ""
Write-Host "Selected Profile: $SelectedProfile"
Write-Host "Profile Directory: $ProfileDir"

# 5. Ask whether to install a user.js at all
$DefaultUrl = 'https://raw.githubusercontent.com/yokoffing/Betterfox/refs/heads/main/user.js'
$UserJsInstalled = $false

Write-Host ""
$userJsChoice = Read-Host "Would you like to install a user.js too? (Y/n)"
if ([string]::IsNullOrWhiteSpace($userJsChoice) -or $userJsChoice -match '^[Yy]') {

    # 6. Fetch it and install it as user.js (whatever the original file was called)
    Write-Host ""
    Write-Host "Press [ENTER] to use the default Betterfox user.js, or paste a raw GitHub link or a local file path (e.g. ~\Downloads\custom.js):"

    $tmp = [IO.Path]::GetTempFileName()
    while ($true) {
        $src = Read-Host "Link or path"
        $usingDefault = [string]::IsNullOrWhiteSpace($src)
        if ($usingDefault) { $src = $DefaultUrl }

        if (Get-FileFromSource -Source $src -Destination $tmp) {
            Copy-Item -LiteralPath $tmp -Destination $UserJsPath -Force
            Write-Host "Successfully installed user.js to $UserJsPath"
            $UserJsInstalled = $true
            break
        } elseif ($usingDefault) {
            Write-Host "Error: Failed to fetch the default user.js. Please check your connection."
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            exit 1
        } else {
            Write-Host "Please try again, or press [ENTER] to use the default."
        }
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Skipping user.js."
}

# 7. Optionally install a userChrome.css
$DefaultCssUrl = 'https://raw.githubusercontent.com/beats-beats/minimal-firefox-css/refs/heads/main/userChrome.css'
$CssInstalled = $false

Write-Host ""
$cssChoice = Read-Host "Would you like to install a userChrome.css too? (Y/n)"
if ([string]::IsNullOrWhiteSpace($cssChoice) -or $cssChoice -match '^[Yy]') {
    Write-Host ""
    Write-Host "Press [ENTER] to use the default userChrome.css, or paste a raw GitHub link or a local file path (e.g. ~\Downloads\mycss.css):"

    $cssTmp = [IO.Path]::GetTempFileName()
    while ($true) {
        $cssSrc = Read-Host "Link or path"
        $usingDefault = [string]::IsNullOrWhiteSpace($cssSrc)
        if ($usingDefault) { $cssSrc = $DefaultCssUrl }

        # Fetch to a temp file first so a failure never touches an existing userChrome.css
        if (Get-FileFromSource -Source $cssSrc -Destination $cssTmp) {
            # Create the chrome folder next to user.js
            New-Item -ItemType Directory -Path $ChromeDir -Force | Out-Null
            $CssPath = Join-Path $ChromeDir 'userChrome.css'

            # Keep a backup of any existing userChrome.css
            if (Test-Path -LiteralPath $CssPath) {
                Copy-Item -LiteralPath $CssPath -Destination "$CssPath.bak" -Force
                Write-Host "Existing userChrome.css backed up to $CssPath.bak"
            }

            Copy-Item -LiteralPath $cssTmp -Destination $CssPath -Force
            Write-Host "Successfully installed userChrome.css to $CssPath"
            $CssInstalled = $true

            # Firefox ignores userChrome.css unless this pref is enabled
            Enable-LegacyStylesheets -UserJsPath $UserJsPath
            break
        } elseif ($usingDefault) {
            Write-Host "Error: Failed to fetch the default userChrome.css. Skipping it."
            break
        } else {
            Write-Host "Please try again, or press [ENTER] to use the default."
        }
    }
    Remove-Item -LiteralPath $cssTmp -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Skipping userChrome.css."
}

# 8. Optionally install a userContent.css
$DefaultContentUrl = 'https://raw.githubusercontent.com/beats-beats/minimal-firefox-css/refs/heads/main/userContent.css'
$ContentInstalled = $false

Write-Host ""
$contentChoice = Read-Host "Would you like to install a userContent.css too? (Y/n)"
if ([string]::IsNullOrWhiteSpace($contentChoice) -or $contentChoice -match '^[Yy]') {
    Write-Host ""
    Write-Host "Press [ENTER] to use the default userContent.css, or paste a raw GitHub link or a local file path (e.g. ~\Downloads\my-content.css):"

    $contentTmp = [IO.Path]::GetTempFileName()
    while ($true) {
        $contentSrc = Read-Host "Link or path"
        $usingDefault = [string]::IsNullOrWhiteSpace($contentSrc)
        if ($usingDefault) { $contentSrc = $DefaultContentUrl }

        # Fetch to a temp file first so a failure never touches an existing userContent.css
        if (Get-FileFromSource -Source $contentSrc -Destination $contentTmp) {
            New-Item -ItemType Directory -Path $ChromeDir -Force | Out-Null
            $ContentPath = Join-Path $ChromeDir 'userContent.css'

            # Keep a backup of any existing userContent.css
            if (Test-Path -LiteralPath $ContentPath) {
                Copy-Item -LiteralPath $ContentPath -Destination "${ContentPath}.bak" -Force
                Write-Host "Existing userContent.css backed up to $ContentPath.bak"
            }

            Copy-Item -LiteralPath $contentTmp -Destination $ContentPath -Force
            Write-Host "Successfully installed userContent.css to $ContentPath"
            $ContentInstalled = $true

            # Same pref as userChrome.css - enable it if this is the only file installed
            Enable-LegacyStylesheets -UserJsPath $UserJsPath
            break
        } elseif ($usingDefault) {
            Write-Host "Error: Failed to fetch the default userContent.css. Skipping it."
            break
        } else {
            Write-Host "Please try again, or press [ENTER] to use the default."
        }
    }
    Remove-Item -LiteralPath $contentTmp -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Skipping userContent.css."
}

# 9. Build the summary of what was changed
$Applied = @()
if ($UserJsInstalled)  { $Applied += 'user.js' }
if ($CssInstalled)     { $Applied += 'userChrome.css' }
if ($ContentInstalled) { $Applied += 'userContent.css' }

# 10. If every step was declined there is nothing to restart
if ($Applied.Count -eq 0) {
    Write-Host ""
    Write-Host "Nothing was installed - no changes were made."
    exit 0
}
$AppliedMsg = $Applied -join ' + '

# 11. Check if Firefox is running and prompt for a restart
$running = @(Get-Process -Name firefox -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Host ""
    Write-Host "Firefox is currently running."
    $restart = Read-Host "Would you like to restart Firefox now to apply changes? (y/n)"
    if ($restart -match '^[Yy]') {
        # Remember where firefox.exe lives before closing it
        $exe = ($running | Where-Object { $_.Path } | Select-Object -First 1).Path
        if (-not $exe) { $exe = Find-Firefox }

        Write-Host "Closing Firefox..."
        foreach ($proc in $running) {
            try { [void]$proc.CloseMainWindow() } catch { }
        }
        $running | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
        Get-Process -Name firefox -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2   # let it cleanly release files

        Write-Host "Reopening Firefox with profile '$SelectedProfile'..."
        Start-FirefoxProfile -Exe $exe -ProfileName $SelectedProfile
    } else {
        Write-Host "Changes saved. Please manually restart Firefox later to apply the $AppliedMsg configurations."
    }
} else {
    # If not running, ask if they want to launch it
    $launch = Read-Host "Firefox is closed. Launch it now with profile '$SelectedProfile'? (y/n)"
    if ($launch -match '^[Yy]*$') {
        Start-FirefoxProfile -Exe (Find-Firefox) -ProfileName $SelectedProfile
    }
}

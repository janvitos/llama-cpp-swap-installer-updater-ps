#Requires -Version 5.1
<#
.SYNOPSIS
    Installer and updater for llama-swap and llama.cpp on Windows.
.DESCRIPTION
    Downloads, installs, and optionally configures llama-swap and llama.cpp.

    On first run, walks through the full install and configuration wizard.
    On subsequent runs, detects an existing installation and only checks for
    binary updates -- no prompts, safe to use as a scheduled update task.

    Use -Reconfigure to force the full wizard to run again.
    Use -Scan to update config.yaml and opencode.json without touching the binaries.

    Directories created:
      <script_root>\llama-swap\   - llama-swap binary + config
      <script_root>\llama.cpp\    - llama.cpp binaries (+ CUDA runtime if applicable)
.PARAMETER Reconfigure
    Force the full configuration wizard even if the installation is already complete.
.PARAMETER Rescan
    Re-scan the model directory and regenerate config.yaml and opencode.json without
    downloading or updating any binaries.
#>
param(
    [switch]$Reconfigure,
    [switch]$Scan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2 for older PowerShell / Windows versions
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# -------------------------------------------------------------------------------
# Paths and constants
# -------------------------------------------------------------------------------

$ScriptRoot     = Split-Path -Parent $MyInvocation.MyCommand.Path
$LlamaSwapDir   = Join-Path $ScriptRoot 'llama-swap'
$LlamaCppDir    = Join-Path $ScriptRoot 'llama.cpp'
$DownloadDir    = Join-Path $ScriptRoot '.downloads'
$SettingsFile   = Join-Path $ScriptRoot 'settings.json'

$GH_API             = 'https://api.github.com/repos'
$REPO_LLAMA_SWAP    = 'mostlygeek/llama-swap'
$REPO_LLAMA_CPP     = 'ggml-org/llama.cpp'

# -------------------------------------------------------------------------------
# Console helpers
# -------------------------------------------------------------------------------

function Write-Banner {
    $sep = '-' * 60
    Write-Host ''
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host '  llama-swap + llama.cpp  |  Installer / Updater' -ForegroundColor Cyan
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Section ([string]$Title) {
    $pad = '-' * [Math]::Max(0, 55 - $Title.Length)
    Write-Host ''
    Write-Host "  -- $Title $pad" -ForegroundColor Yellow
    Write-Host ''
}

function Write-Ok   ([string]$Msg) { Write-Host "  [OK] $Msg" -ForegroundColor Green  }
function Write-Info ([string]$Msg) { Write-Host "  [..] $Msg" -ForegroundColor Gray   }
function Write-Warn ([string]$Msg) { Write-Host "  [!!] $Msg" -ForegroundColor Yellow }
function Write-Do   ([string]$Msg) { Write-Host "  [>>] $Msg" -ForegroundColor Cyan   }

function Read-Confirm ([string]$Prompt, [bool]$Default = $true) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $r    = (Read-Host "  $Prompt ($hint)").Trim()
    if ([string]::IsNullOrEmpty($r)) { return $Default }
    return $r -match '^[yY]$'
}

function Read-OptionalParam ([string]$Label, [string]$Saved) {
    $hint = if ($Saved) { "[$Saved] (- to clear)" } else { '(Enter to omit)' }
    $val  = (Read-Host "  $Label $hint").Trim()
    if ([string]::IsNullOrEmpty($val)) { return $Saved }
    if ($val -eq '-') { return '' }
    return $val
}

# -------------------------------------------------------------------------------
# GitHub API
# -------------------------------------------------------------------------------

function Get-LatestRelease ([string]$Repo) {
    $uri = "$GH_API/$Repo/releases/latest"
    try {
        return Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'llama-installer/1.0' }
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 403) {
            throw 'GitHub API rate limit reached. Wait a few minutes and try again.'
        }
        throw "Failed to fetch release info for '$Repo': $_"
    }
}

# -------------------------------------------------------------------------------
# Settings  (persists user choices across runs)
# -------------------------------------------------------------------------------

function Read-Settings {
    $defaults = @{
        ModelDir   = ''
        ListenHost = 'localhost'
        ListenPort = '8080'
        Params     = @{
            CtxVal = 65536; OutVal = 8192; FullGpu = $true
            TempStr = ''; TopPStr = ''; TopKStr = ''
            MinPStr = ''; RepPenStr = ''; PresPenStr = ''
        }
    }
    if (-not (Test-Path $SettingsFile)) { return $defaults }
    try {
        $json = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        if ($json.ModelDir)   { $defaults.ModelDir   = $json.ModelDir }
        if ($json.ListenHost) { $defaults.ListenHost = $json.ListenHost }
        if ($json.ListenPort) { $defaults.ListenPort = $json.ListenPort }
        if ($json.Params) {
            $p = $json.Params
            if ($null -ne $p.CtxVal)     { $defaults.Params.CtxVal     = [int]$p.CtxVal }
            if ($null -ne $p.OutVal)     { $defaults.Params.OutVal     = [int]$p.OutVal }
            if ($null -ne $p.FullGpu)    { $defaults.Params.FullGpu    = [bool]$p.FullGpu }
            if ($null -ne $p.TempStr)    { $defaults.Params.TempStr    = [string]$p.TempStr }
            if ($null -ne $p.TopPStr)    { $defaults.Params.TopPStr    = [string]$p.TopPStr }
            if ($null -ne $p.TopKStr)    { $defaults.Params.TopKStr    = [string]$p.TopKStr }
            if ($null -ne $p.MinPStr)    { $defaults.Params.MinPStr    = [string]$p.MinPStr }
            if ($null -ne $p.RepPenStr)  { $defaults.Params.RepPenStr  = [string]$p.RepPenStr }
            if ($null -ne $p.PresPenStr) { $defaults.Params.PresPenStr = [string]$p.PresPenStr }
        }
    } catch { }
    return $defaults
}

function Save-Settings ([hashtable]$Updates) {
    $current = Read-Settings
    foreach ($key in $Updates.Keys) { $current[$key] = $Updates[$key] }
    $current | ConvertTo-Json -Depth 5 | Set-Content -Path $SettingsFile -Encoding UTF8
}

# -------------------------------------------------------------------------------
# Version tracking  (each install dir keeps a .version file)
# -------------------------------------------------------------------------------

function Get-LocalVersion ([string]$Dir) {
    $f = Join-Path $Dir '.version'
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
    return ''
}

function Save-LocalVersion ([string]$Dir, [string]$Version) {
    Set-Content -Path (Join-Path $Dir '.version') -Value $Version -Encoding UTF8
}

# -------------------------------------------------------------------------------
# Download + extract
# -------------------------------------------------------------------------------

function Invoke-Download ([string]$Url, [string]$OutFile) {
    $fileName = Split-Path -Leaf $OutFile
    Write-Do "Downloading $fileName..."

    # HEAD request to get total size for the progress bar
    $total = 0L
    try {
        $req           = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method    = 'HEAD'
        $req.UserAgent = 'llama-installer/1.0'
        $resp  = $req.GetResponse()
        $total = $resp.ContentLength
        $resp.Dispose()
    } catch { }

    # Download on a thread pool thread; poll the output file size for progress
    $wc   = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'llama-installer/1.0')
    $task = $wc.DownloadFileTaskAsync([Uri]$Url, $OutFile)

    $barWidth = 40
    $lastPct  = -1

    try {
        while (-not $task.IsCompleted) {
            if ($total -gt 0) {
                try {
                    $downloaded = (Get-Item $OutFile -ErrorAction Stop).Length
                    $pct        = [math]::Min(99, [int]($downloaded / $total * 100))
                    if ($pct -ne $lastPct) {
                        $filled = [int]($pct / 100 * $barWidth)
                        $bar    = ('=' * $filled) + ('-' * ($barWidth - $filled))
                        $dlMb   = '{0:N1}' -f ($downloaded / 1MB)
                        $totMb  = '{0:N1}' -f ($total / 1MB)
                        Write-Host "`r  [$bar] $pct% ($dlMb / $totMb MB)  " -NoNewline
                        $lastPct = $pct
                    }
                } catch { }
            } else {
                Write-Host "`r  Downloading...  " -NoNewline
            }
            Start-Sleep -Milliseconds 200
        }
    } finally {
        $wc.Dispose()
    }

    if ($task.IsFaulted) { throw $task.Exception.InnerException }

    Write-Host "`r  [$('=' * $barWidth)] 100%                              "
    Write-Ok "$fileName downloaded."
}

function Expand-ToDir ([string]$Zip, [string]$Dest) {
    # Extracts $Zip into $Dest, merging with any existing content.
    # If the zip contains a single top-level folder (GitHub release convention),
    # its contents are promoted directly into $Dest so there is no extra nesting.

    $staging = Join-Path $DownloadDir "_staging_$([System.IO.Path]::GetFileNameWithoutExtension($Zip))"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }

    Expand-Archive -Path $Zip -DestinationPath $staging -Force

    if (-not (Test-Path $Dest)) {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    }

    $items = @(Get-ChildItem $staging)
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
        # Single subfolder -- promote its contents
        Get-ChildItem $items[0].FullName | Copy-Item -Destination $Dest -Recurse -Force
    }
    else {
        Get-ChildItem $staging | Copy-Item -Destination $Dest -Recurse -Force
    }

    Remove-Item $staging -Recurse -Force
}

# -------------------------------------------------------------------------------
# llama-swap
# -------------------------------------------------------------------------------

function Install-Or-Update-LlamaSwap {
    Write-Section 'llama-swap'

    $rel    = Get-LatestRelease -Repo $REPO_LLAMA_SWAP
    $latest = $rel.tag_name
    $local  = Get-LocalVersion -Dir $LlamaSwapDir

    Write-Info "Latest    : $latest"
    if ($local) { Write-Info "Installed : $local" }
    else        { Write-Info "Installed : (not found)" }

    if ($local -eq $latest -and (Test-Path $LlamaSwapDir)) {
        Write-Ok 'llama-swap is already up to date.'
        return
    }

    # Locate the Windows asset.
    # goreleaser typically produces: llama-swap_Windows_x86_64.zip
    # Also matches variants: win, windows, amd64, x86_64, x64.
    $asset = $rel.assets | Where-Object {
        $_.name -match '(?i)(windows|win).*(x86_64|amd64|x64).*\.zip$'
    } | Select-Object -First 1

    if (-not $asset) {
        Write-Warn 'Could not automatically find a Windows asset. Available assets:'
        $rel.assets | ForEach-Object { Write-Info "  $($_.name)" }
        throw "No Windows asset found for llama-swap $latest. Check the release page manually."
    }

    Write-Info "Asset     : $($asset.name)"

    $zip = Join-Path $DownloadDir $asset.name
    Invoke-Download -Url $asset.browser_download_url -OutFile $zip

    Write-Do "Installing to $LlamaSwapDir ..."
    if (Test-Path $LlamaSwapDir) { Remove-Item $LlamaSwapDir -Recurse -Force }
    Expand-ToDir -Zip $zip -Dest $LlamaSwapDir
    Remove-Item $zip -Force

    Save-LocalVersion -Dir $LlamaSwapDir -Version $latest
    Write-Ok "llama-swap $latest installed."
}

# -------------------------------------------------------------------------------
# llama.cpp
# -------------------------------------------------------------------------------

function Get-WindowsBuilds ($Assets) {
    # Match: llama-b1234-bin-win-<buildtype>-x64.zip
    return @($Assets | Where-Object {
        $_.name -match '^llama-[^-]+-bin-win-.+-x64\.zip$'
    } | Sort-Object { $_.name })
}

function Get-CudartAsset ($Assets, [string]$CudaVersion) {
    return $Assets | Where-Object {
        $_.name -like "cudart-llama-bin-win-cuda-$CudaVersion-x64.zip"
    } | Select-Object -First 1
}

function Select-Build ($Builds, [string]$CurrentBuild) {
    $labels = $Builds | ForEach-Object {
        if ($_.name -match '^llama-[^-]+-bin-win-(.+)-x64\.zip$') { $Matches[1] } else { $_.name }
    }

    $cursor = 0
    for ($i = 0; $i -lt $labels.Count; $i++) {
        if ($labels[$i] -eq $CurrentBuild) { $cursor = $i; break }
    }

    Write-Host '  Available llama.cpp Windows builds:' -ForegroundColor Cyan
    Write-Host '  Use arrow keys to select, Enter to confirm.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Notes:' -ForegroundColor DarkGray
    Write-Host '  * CUDA builds (green) require an NVIDIA GPU' -ForegroundColor DarkGray
    Write-Host '  * avx2   -- recommended for most modern CPUs (Intel Haswell+ / AMD Ryzen)' -ForegroundColor DarkGray
    Write-Host '  * vulkan -- GPU acceleration via Vulkan; works on AMD, Intel, and NVIDIA' -ForegroundColor DarkGray
    Write-Host '  * avx    -- for older CPUs that lack AVX2 support' -ForegroundColor DarkGray
    Write-Host ''

    $esc     = [char]27
    $maxLen  = ($labels | ForEach-Object {
        $marker = if ($_ -eq $CurrentBuild) { '  <- current' } else { '' }
        "  $_$marker".Length
    } | Measure-Object -Maximum).Maximum + 4  # 4 chars right-padding

    function Draw-Menu ([int]$Selected) {
        for ($i = 0; $i -lt $labels.Count; $i++) {
            $label  = $labels[$i]
            $isCuda = $label -match '^cuda-'
            $marker = if ($label -eq $CurrentBuild) { '  <- current' } else { '' }
            $text   = "  $label$marker".PadRight($maxLen)

            if ($i -eq $Selected) {
                Write-Host $text -BackgroundColor DarkGreen -ForegroundColor White
            } elseif ($isCuda) {
                Write-Host $text -ForegroundColor DarkGreen
            } else {
                Write-Host $text -ForegroundColor DarkGray
            }
        }
    }

    Draw-Menu $cursor

    while ($true) {
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        switch ($key.VirtualKeyCode) {
            38 {  # Up
                if ($cursor -gt 0) {
                    $cursor--
                    [Console]::Write("$esc[$($labels.Count)A")
                    Draw-Menu $cursor
                }
            }
            40 {  # Down
                if ($cursor -lt $labels.Count - 1) {
                    $cursor++
                    [Console]::Write("$esc[$($labels.Count)A")
                    Draw-Menu $cursor
                }
            }
            13 {  # Enter
                Write-Host ''
                return @{ Asset = $Builds[$cursor]; Type = $labels[$cursor] }
            }
        }
    }
}

function Install-Or-Update-LlamaCpp {
    Write-Section 'llama.cpp'

    $rel    = Get-LatestRelease -Repo $REPO_LLAMA_CPP
    $latest = $rel.tag_name
    $local  = Get-LocalVersion -Dir $LlamaCppDir

    $btFile       = Join-Path $LlamaCppDir '.buildtype'
    $currentBuild = ''
    if (Test-Path $btFile) { $currentBuild = (Get-Content $btFile -Raw).Trim() }

    Write-Info "Latest    : $latest"
    if ($local) { Write-Info "Installed : $local  [$currentBuild]" }
    else        { Write-Info "Installed : (not found)" }

    if ($local -eq $latest -and (Test-Path $LlamaCppDir)) {
        Write-Ok 'llama.cpp is already up to date.'
        return $currentBuild
    }

    $builds = Get-WindowsBuilds -Assets $rel.assets
    if ($builds.Count -eq 0) { throw "No Windows builds found for llama.cpp $latest." }

    $choice    = Select-Build -Builds $builds -CurrentBuild $currentBuild
    $selected  = $choice.Asset
    $buildType = $choice.Type

    # Download main binary zip
    $zip = Join-Path $DownloadDir $selected.name
    Invoke-Download -Url $selected.browser_download_url -OutFile $zip

    # Download matching CUDA runtime if this is a CUDA build
    $cudaZip = $null
    if ($buildType -match '^cuda-(.+)$') {
        $cudaVer = $Matches[1]
        Write-Info "CUDA build detected - looking for cudart (cuda $cudaVer)..."

        $cudart = Get-CudartAsset -Assets $rel.assets -CudaVersion $cudaVer
        if ($cudart) {
            Write-Info "Found: $($cudart.name)"
            $cudaZip = Join-Path $DownloadDir $cudart.name
            Invoke-Download -Url $cudart.browser_download_url -OutFile $cudaZip
        }
        else {
            Write-Warn "No matching cudart zip found for cuda-$cudaVer in this release."
            Write-Warn 'CUDA DLLs may be missing. Install the CUDA Toolkit from nvidia.com if needed.'
        }
    }

    Write-Do "Installing to $LlamaCppDir ..."
    if (Test-Path $LlamaCppDir) { Remove-Item $LlamaCppDir -Recurse -Force }

    Expand-ToDir -Zip $zip -Dest $LlamaCppDir
    Remove-Item $zip -Force

    if ($cudaZip -and (Test-Path $cudaZip)) {
        Write-Do 'Merging CUDA runtime DLLs...'
        Expand-ToDir -Zip $cudaZip -Dest $LlamaCppDir
        Remove-Item $cudaZip -Force
    }

    Save-LocalVersion -Dir $LlamaCppDir -Version $latest
    Set-Content -Path $btFile -Value $buildType -Encoding UTF8

    Write-Ok "llama.cpp $latest [$buildType] installed."
    return $buildType
}

# -------------------------------------------------------------------------------
# Model directory selection
# -------------------------------------------------------------------------------

function Select-ModelDirectory {
    Write-Section 'Model Directory'

    $saved      = Read-Settings
    $defaultDir = if ($saved.ModelDir -and (Test-Path $saved.ModelDir)) { $saved.ModelDir } else { Join-Path $ScriptRoot 'models' }

    Write-Host '  Where are your .gguf model files located?' -ForegroundColor Cyan
    Write-Host '  Press Enter to use the default, or type a custom path.' -ForegroundColor DarkGray
    Write-Host ''

    $customDir = (Read-Host "  Model directory [$defaultDir]").Trim()
    $modelDir  = if ([string]::IsNullOrEmpty($customDir)) { $defaultDir } else { $customDir }

    if ($modelDir -eq $defaultDir -and -not (Test-Path $modelDir)) {
        New-Item -ItemType Directory -Path $modelDir -Force | Out-Null
        Write-Ok "Created $modelDir"
        Write-Host ''
        Write-Host '  Please place your .gguf model files in:' -ForegroundColor Yellow
        Write-Host "    $modelDir" -ForegroundColor White
        Write-Host ''
        Read-Host '  Press Enter when ready to scan for models'
    } elseif (-not (Test-Path $modelDir)) {
        Write-Warn "Directory not found: $modelDir"
        Write-Info 'Skipping config.yaml and opencode.json.'
        return $null
    }

    return $modelDir
}

# -------------------------------------------------------------------------------
# Parameter helpers  (shared between config wizard and --scan)
# -------------------------------------------------------------------------------

function Read-ModelParams {
    $d = (Read-Settings).Params

    $ctxStr = (Read-Host "  Context window size [$($d.CtxVal)]").Trim()
    $ctxVal = 0
    if (-not [int]::TryParse($ctxStr, [ref]$ctxVal) -or $ctxVal -le 0) { $ctxVal = $d.CtxVal }

    $outStr = (Read-Host "  Max output tokens for opencode [$($d.OutVal)]").Trim()
    $outVal = 0
    if (-not [int]::TryParse($outStr, [ref]$outVal) -or $outVal -le 0) { $outVal = $d.OutVal }

    $fullGpu    = Read-Confirm 'Load model fully on GPU (--gpu-layers 999)?' -Default $d.FullGpu
    $tempStr    = Read-OptionalParam 'Temperature     ' $d.TempStr
    $topPStr    = Read-OptionalParam 'Top_P           ' $d.TopPStr
    $topKStr    = Read-OptionalParam 'Top_K           ' $d.TopKStr
    $minPStr    = Read-OptionalParam 'Min_P           ' $d.MinPStr
    $repPenStr  = Read-OptionalParam 'Repeat Penalty  ' $d.RepPenStr
    $presPenStr = Read-OptionalParam 'Presence Penalty' $d.PresPenStr

    $params = @{
        CtxVal = $ctxVal;  OutVal      = $outVal
        FullGpu = $fullGpu; TempStr    = $tempStr
        TopPStr = $topPStr; TopKStr    = $topKStr
        MinPStr = $minPStr; RepPenStr  = $repPenStr
        PresPenStr = $presPenStr
    }
    Save-Settings @{ Params = $params }
    return $params
}

function Build-ModelEntry ([string]$Name, [string]$ModelPath, [hashtable]$Params) {
    $llamaServerExe = Join-Path $LlamaCppDir 'llama-server.exe'
    $cmd = "$llamaServerExe -m `"$ModelPath`" --port `${PORT} --ctx-size $($Params.CtxVal) --jinja --flash-attn on"
    if ($Params.FullGpu)                                         { $cmd += ' --gpu-layers 999' }
    if (-not [string]::IsNullOrEmpty($Params.TempStr))          { $cmd += " --temp $($Params.TempStr)" }
    if (-not [string]::IsNullOrEmpty($Params.TopPStr))          { $cmd += " --top-p $($Params.TopPStr)" }
    if (-not [string]::IsNullOrEmpty($Params.TopKStr))          { $cmd += " --top-k $($Params.TopKStr)" }
    if (-not [string]::IsNullOrEmpty($Params.MinPStr))          { $cmd += " --min-p $($Params.MinPStr)" }
    if (-not [string]::IsNullOrEmpty($Params.RepPenStr))        { $cmd += " --repeat-penalty $($Params.RepPenStr)" }
    if (-not [string]::IsNullOrEmpty($Params.PresPenStr))       { $cmd += " --presence-penalty $($Params.PresPenStr)" }
    return @{ Name = $Name; Cmd = $cmd; ContextLimit = $Params.CtxVal; OutputLimit = $Params.OutVal }
}

function Write-SwapConfig ([System.Collections.Generic.List[hashtable]]$Models, [string]$ConfigPath) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('healthCheckTimeout: 60')
    [void]$sb.AppendLine('globalTTL: 600')
    [void]$sb.AppendLine('startPort: 8081')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('models:')
    if ($Models.Count -eq 0) {
        [void]$sb.AppendLine('  # No models defined.')
    } else {
        foreach ($m in $Models) {
            $yamlCmd = $m.Cmd -replace "'", "''"
            [void]$sb.AppendLine("  $($m.Name):")
            [void]$sb.AppendLine("    cmd: '$yamlCmd'")
        }
    }
    Set-Content -Path $ConfigPath -Value $sb.ToString() -Encoding UTF8
}

# -------------------------------------------------------------------------------
# llama-swap  config.yaml
# -------------------------------------------------------------------------------

function New-LlamaSwapConfig ([string]$ModelDir) {
    Write-Section 'llama-swap - config.yaml'

    # Scan model directory for .gguf files
    $ggufFiles = @(Get-ChildItem -Path $ModelDir -Filter '*.gguf' | Sort-Object Name)

    if ($ggufFiles.Count -eq 0) {
        Write-Warn "No .gguf files found in $ModelDir"
        Write-Info 'Skipping config.yaml and opencode.json.'
        return $null
    }

    Write-Do "Found $($ggufFiles.Count) model(s) in $ModelDir"
    $ggufFiles | ForEach-Object { Write-Info "  $($_.Name)" }

    $configPath = Join-Path $LlamaSwapDir 'config.yaml'

    if (Test-Path $configPath) {
        Write-Host ''
        Write-Info "config.yaml already exists: $configPath"
        if (-not (Read-Confirm 'Overwrite it?')) {
            Write-Info 'Keeping existing config.yaml.'
            return $null
        }
    }

    # Server address / port
    Write-Host ''
    Write-Host '  llama-swap listen address / port' -ForegroundColor Cyan
    Write-Host '  (This is where clients like opencode will connect.)' -ForegroundColor DarkGray
    Write-Host ''

    $saved = Read-Settings
    $addr  = (Read-Host "  Server host [$($saved.ListenHost)]").Trim()
    if ([string]::IsNullOrEmpty($addr)) { $addr = $saved.ListenHost }

    $port = (Read-Host "  Server port [$($saved.ListenPort)]").Trim()
    if ([string]::IsNullOrEmpty($port)) { $port = $saved.ListenPort }

    $listenAddr    = "${addr}:${port}"
    $serverBaseUrl = "http://${addr}:${port}"

    Write-Host ''
    Write-Host '  Configure each model. Press Enter on optional fields to omit the flag.' -ForegroundColor Cyan
    Write-Host ''

    $models = [System.Collections.Generic.List[hashtable]]::new()
    $total  = $ggufFiles.Count

    $sharedParams = $null
    if ($total -gt 1) {
        Write-Host ''
        if (Read-Confirm 'Use the same parameters for all models?') {
            Write-Host ''
            Write-Host '  -- Shared parameters (applied to all models) --' -ForegroundColor Yellow
            Write-Host ''
            $sharedParams = Read-ModelParams
            Write-Host ''
        }
    }

    $idx = 1
    foreach ($file in $ggufFiles) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

        Write-Host "  -- Model $idx/$total : $name" -ForegroundColor Yellow
        Write-Host ''

        $entryParams = if ($sharedParams) { $sharedParams } else { Read-ModelParams }
        $entry = Build-ModelEntry -Name $name -ModelPath $file.FullName -Params $entryParams
        $models.Add($entry)
        Write-Ok "Configured: $name"
        Write-Info "  cmd: $($entry.Cmd)"
        Write-Host ''
        $idx++
    }

    if (-not (Test-Path $LlamaSwapDir)) {
        New-Item -ItemType Directory -Path $LlamaSwapDir -Force | Out-Null
    }

    Write-SwapConfig -Models $models -ConfigPath $configPath
    Write-Ok "config.yaml written to $configPath"

    Save-Settings @{ ModelDir = $ModelDir; ListenHost = $addr; ListenPort = $port }

    return @{
        Models        = $models
        ServerBaseUrl = $serverBaseUrl
        ListenAddr    = $listenAddr
    }
}

# -------------------------------------------------------------------------------
# opencode  opencode.json
# -------------------------------------------------------------------------------

function New-OpencodeConfig ([string]$BaseUrl, $Models) {
    Write-Section 'opencode - opencode.json'

    if (-not (Read-Confirm 'Create / update opencode.json?')) {
        Write-Info 'Skipping opencode configuration.'
        return
    }

    $opencodeDir  = Join-Path $env:USERPROFILE '.config\opencode'
    $opencodeFile = Join-Path $opencodeDir 'opencode.json'

    if (-not (Test-Path $opencodeDir)) {
        New-Item -ItemType Directory -Path $opencodeDir -Force | Out-Null
    }

    $apiUrl = "$BaseUrl/v1"

    # Build the models object block -- each model is a keyed entry with name + limits
    $modelEntries = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $Models) {
        $entry = @"
        "$($m.Name)": {
          "name": "$($m.Name)",
          "limit": {
            "context": $($m.ContextLimit),
            "output": $($m.OutputLimit)
          }
        }
"@
        $modelEntries.Add($entry.TrimEnd())
    }
    $modelsBlock = $modelEntries -join ",`n"

    $json = @"
{
  "`$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama-swap": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama-swap",
      "options": {
        "baseURL": "$apiUrl"
      },
      "models": {
$modelsBlock
      }
    }
  }
}
"@

    Set-Content -Path $opencodeFile -Value $json -Encoding UTF8
    Write-Ok "opencode.json written to $opencodeFile"
}

# -------------------------------------------------------------------------------
# Scan helpers
# -------------------------------------------------------------------------------

function Parse-CmdString ([string]$Cmd) {
    $p = @{
        CtxVal = 65536; OutVal = 8192; FullGpu = $true
        TempStr = ''; TopPStr = ''; TopKStr = ''
        MinPStr = ''; RepPenStr = ''; PresPenStr = ''
    }
    if ($Cmd -match '--ctx-size\s+(\d+)')            { $p.CtxVal     = [int]$Matches[1] }
    if ($Cmd -match '--gpu-layers\s+999')            { $p.FullGpu    = $true }
    if ($Cmd -match '--temp\s+([\d.]+)')             { $p.TempStr    = $Matches[1] }
    if ($Cmd -match '--top-p\s+([\d.]+)')            { $p.TopPStr    = $Matches[1] }
    if ($Cmd -match '--top-k\s+(\d+)')               { $p.TopKStr    = $Matches[1] }
    if ($Cmd -match '--min-p\s+([\d.]+)')            { $p.MinPStr    = $Matches[1] }
    if ($Cmd -match '--repeat-penalty\s+([\d.]+)')   { $p.RepPenStr  = $Matches[1] }
    if ($Cmd -match '--presence-penalty\s+([\d.]+)') { $p.PresPenStr = $Matches[1] }
    return $p
}

function Read-ConfigModels {
    $configPath = Join-Path $LlamaSwapDir 'config.yaml'
    $result = @{}
    if (-not (Test-Path $configPath)) { return $result }
    $lines = Get-Content $configPath
    $currentModel = $null
    foreach ($line in $lines) {
        if ($line -match '^  ([^#][^:]*):$') {
            $currentModel = $Matches[1].Trim()
        } elseif ($currentModel -and $line -match "^    cmd:\s+'(.*)'$") {
            $result[$currentModel] = $Matches[1] -replace "''", "'"
            $currentModel = $null
        }
    }
    return $result
}

function Read-OpencodeModels {
    $opencodeFile = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    $result = @{}
    if (-not (Test-Path $opencodeFile)) { return $result }
    try {
        $json     = Get-Content $opencodeFile -Raw | ConvertFrom-Json
        $provider = $json.provider.'llama-swap'
        if ($provider -and $provider.models) {
            $provider.models.PSObject.Properties | ForEach-Object {
                $result[$_.Name] = @{
                    Context = [int]$_.Value.limit.context
                    Output  = [int]$_.Value.limit.output
                }
            }
        }
    } catch { }
    return $result
}

function Read-ExistingListenAddr {
    $batFile = Join-Path $ScriptRoot 'start-llama-swap.bat'
    if (Test-Path $batFile) {
        $content = Get-Content $batFile -Raw
        if ($content -match '--listen\s+(\S+)') { return $Matches[1] }
    }
    return 'localhost:8080'
}

function Show-DefaultParams ([hashtable]$Params) {
    Write-Host '  Default parameters (from existing models):' -ForegroundColor Cyan
    Write-Host "    Context window : $($Params.CtxVal)" -ForegroundColor White
    Write-Host "    Max output     : $($Params.OutVal)" -ForegroundColor White
    $gpuLabel = if ($Params.FullGpu) { 'Yes (--gpu-layers 999)' } else { 'No' }
    Write-Host "    GPU offload    : $gpuLabel" -ForegroundColor White
    $samplers = @()
    if ($Params.TempStr)    { $samplers += "temp=$($Params.TempStr)" }
    if ($Params.TopPStr)    { $samplers += "top_p=$($Params.TopPStr)" }
    if ($Params.TopKStr)    { $samplers += "top_k=$($Params.TopKStr)" }
    if ($Params.MinPStr)    { $samplers += "min_p=$($Params.MinPStr)" }
    if ($Params.RepPenStr)  { $samplers += "repeat_penalty=$($Params.RepPenStr)" }
    if ($Params.PresPenStr) { $samplers += "presence_penalty=$($Params.PresPenStr)" }
    $samplerLine = if ($samplers.Count -gt 0) { $samplers -join ', ' } else { '(defaults)' }
    Write-Host "    Sampling       : $samplerLine" -ForegroundColor White
    Write-Host ''
}

function Invoke-Scan {
    Write-Section 'Model Scan'

    $existingCmds   = Read-ConfigModels
    $existingLimits = Read-OpencodeModels
    $listenAddr     = Read-ExistingListenAddr
    $serverBaseUrl  = "http://$listenAddr"

    # Infer model directory from the existing config, let user confirm or change
    $inferredDir = $null
    foreach ($cmd in $existingCmds.Values) {
        if ($cmd -match '-m\s+"([^"]+)"') {
            $inferredDir = Split-Path -Parent $Matches[1]
            break
        }
    }

    if ($inferredDir -and (Test-Path $inferredDir)) {
        Write-Host '  Previously configured model directory:' -ForegroundColor Cyan
        Write-Host "    $inferredDir" -ForegroundColor White
        Write-Host ''
        if (Read-Confirm 'Scan this directory?') {
            $modelDir = $inferredDir
        } else {
            $modelDir = (Read-Host '  Enter model directory path (or Enter to cancel)').Trim()
            if ([string]::IsNullOrEmpty($modelDir) -or -not (Test-Path $modelDir)) {
                Write-Info 'Scan cancelled.'
                return
            }
        }
    } else {
        $modelDir = Select-ModelDirectory
        if (-not $modelDir) { return }
    }

    # Persist the resolved model directory
    Save-Settings @{ ModelDir = $modelDir }

    # Scan current .gguf files
    $ggufFiles    = @(Get-ChildItem -Path $modelDir -Filter '*.gguf' | Sort-Object Name)
    $currentNames = @($ggufFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) })

    # Compute diff
    $existingNames  = @($existingCmds.Keys)
    $removedNames   = @($existingNames | Where-Object { $_ -notin $currentNames })
    $addedFiles     = @($ggufFiles    | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -notin $existingNames })
    $unchangedNames = @($existingNames | Where-Object { $_ -in $currentNames })

    Write-Host ''
    Write-Info "Models found : $($ggufFiles.Count)"
    if ($removedNames.Count -gt 0) {
        Write-Warn "Removed ($($removedNames.Count)): $($removedNames -join ', ')"
    }
    if ($addedFiles.Count -gt 0) {
        Write-Do "Added ($($addedFiles.Count)): $(($addedFiles | ForEach-Object { $_.BaseName }) -join ', ')"
    }
    if ($removedNames.Count -eq 0 -and $addedFiles.Count -eq 0) {
        Write-Ok 'No changes detected in model folder.'
    }

    # Start with unchanged models (keep their existing cmd and limits as-is)
    $models = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($name in $unchangedNames) {
        $parsed = Parse-CmdString -Cmd $existingCmds[$name]
        $outVal = if ($existingLimits.ContainsKey($name)) { $existingLimits[$name].Output } else { 8192 }
        $models.Add(@{ Name = $name; Cmd = $existingCmds[$name]; ContextLimit = $parsed.CtxVal; OutputLimit = $outVal })
    }

    # Configure added models
    if ($addedFiles.Count -gt 0) {
        Write-Host ''
        Write-Host "  -- Configuring $($addedFiles.Count) new model(s) --" -ForegroundColor Yellow
        Write-Host ''

        $paramsForNew = $null

        # Offer defaults derived from the first existing model
        if ($existingNames.Count -gt 0) {
            $firstName     = $existingNames | Select-Object -First 1
            $defaultParams = Parse-CmdString -Cmd $existingCmds[$firstName]
            $defaultParams.OutVal = if ($existingLimits.ContainsKey($firstName)) { $existingLimits[$firstName].Output } else { 8192 }

            Show-DefaultParams -Params $defaultParams
            if (Read-Confirm 'Apply these parameters to all new models?') {
                $paramsForNew = $defaultParams
            }
        }

        if (-not $paramsForNew) {
            if ($addedFiles.Count -eq 1) {
                Write-Host ''
                $paramsForNew = Read-ModelParams
            } else {
                Write-Host ''
                if (Read-Confirm 'Use the same parameters for all new models?') {
                    Write-Host ''
                    Write-Host '  -- Shared parameters (applied to all new models) --' -ForegroundColor Yellow
                    Write-Host ''
                    $paramsForNew = Read-ModelParams
                }
            }
        }

        $idx = 1
        foreach ($file in $addedFiles) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            Write-Host "  -- New model $idx/$($addedFiles.Count): $name" -ForegroundColor Yellow
            Write-Host ''
            $p = if ($paramsForNew) { $paramsForNew } else { Read-ModelParams }
            $models.Add((Build-ModelEntry -Name $name -ModelPath $file.FullName -Params $p))
            Write-Ok "Configured: $name"
            $idx++
        }
    }

    # Write output files
    $configPath = Join-Path $LlamaSwapDir 'config.yaml'
    Write-SwapConfig -Models $models -ConfigPath $configPath
    Write-Ok 'config.yaml updated.'

    if ($models.Count -gt 0) {
        New-OpencodeConfig -BaseUrl $serverBaseUrl -Models $models
    }

    $swapExe    = Join-Path $LlamaSwapDir 'llama-swap.exe'
    $batFile    = Join-Path $ScriptRoot 'start-llama-swap.bat'
    $batContent = "@echo off`r`n`"$swapExe`" --config `"$configPath`" --listen $listenAddr`r`npause`r`n"
    Set-Content -Path $batFile -Value $batContent -Encoding ASCII -NoNewline
    Write-Ok 'start-llama-swap.bat updated.'
}

# -------------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------------

function Register-UpdateTask {
    $taskName   = 'llama-cpp-swap-updater'
    $scriptPath = Join-Path $ScriptRoot 'install.ps1'

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        $recreate = Read-Confirm 'A scheduled update task already exists. Recreate it?' -Default $false
        if (-not $recreate) { return }
    }
    else {
        $create = Read-Confirm 'Create a scheduled task to run the updater silently daily and at login?'
        if (-not $create) { return }
    }

    Write-Do 'Registering scheduled task...'

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    # Build the task XML directly so every setting is explicit.
    # LogonType InteractiveToken = runs only when the user is already logged on (no admin/UAC needed)
    # StartWhenAvailable = "Run as soon as possible after a scheduled start is missed"
    # AllowHardTerminate = "If the running task does not end when requested, force it to stop"
    # DisallowStartIfOnBatteries / StopIfGoingOnBatteries = false (AC-power restriction disabled)
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Silently checks for and installs updates to llama.cpp and llama-swap.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2000-01-01T03:00:00</StartBoundary>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
    <LogonTrigger>
      <UserId>$currentUser</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$currentUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$scriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    $tmpXml = Join-Path $env:TEMP 'llama-updater-task.xml'
    [System.IO.File]::WriteAllText($tmpXml, $xml, [System.Text.Encoding]::Unicode)

    try {
        $out      = schtasks.exe /Create /TN $taskName /XML $tmpXml /F 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-Warn "Failed to create scheduled task: $out"
            return
        }
    }
    finally {
        Remove-Item $tmpXml -ErrorAction SilentlyContinue
    }

    Write-Ok "Scheduled task '$taskName' created (daily at 03:00 + at login)."
}

function Main {
    Write-Banner

    Write-Info "Script root : $ScriptRoot"
    Write-Info "llama-swap  : $LlamaSwapDir"
    Write-Info "llama.cpp   : $LlamaCppDir"

    if (-not (Test-Path $DownloadDir)) {
        New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
    }

    # ---- Scan-only mode ---------------------------------------------------------
    if ($Scan) {
        Invoke-Scan
        Write-Section 'Done'
        Write-Ok 'Model scan complete.'
        Write-Host ''
        Write-Host '  Press Enter to exit...' -NoNewline
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return
    }

    # Detect whether a full installation + configuration already exists
    $isConfigured = ((Get-LocalVersion -Dir $LlamaSwapDir) -ne '') -and
                    ((Get-LocalVersion -Dir $LlamaCppDir)  -ne '') -and
                    (Test-Path (Join-Path $LlamaSwapDir 'config.yaml')) -and
                    (Test-Path (Join-Path $ScriptRoot    'start-llama-swap.bat'))

    if ($isConfigured -and -not $Reconfigure) {
        # ---- Update-only mode ------------------------------------------------
        Write-Info 'Existing installation detected -- running in update-only mode.'
        Write-Info 'Run with --reconfigure to redo the full setup wizard.'
        Write-Host ''
        try {
            Install-Or-Update-LlamaSwap
            $null = Install-Or-Update-LlamaCpp
        }
        finally {
            if (Test-Path $DownloadDir) {
                Get-ChildItem $DownloadDir -Filter '*.zip' -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                $remaining = Get-ChildItem $DownloadDir -ErrorAction SilentlyContinue
                if (-not $remaining) { Remove-Item $DownloadDir -Force -ErrorAction SilentlyContinue }
            }
        }
        Write-Section 'Done'
        Write-Ok 'Update check complete.'
        Write-Host ''
        return
    }

    # ---- Full install / reconfigure mode -------------------------------------
    if ($Reconfigure) {
        Write-Info 'Reconfigure flag detected -- running full setup wizard.'
        Write-Host ''
    }

    try {
        # 1. Install / update llama-swap
        Install-Or-Update-LlamaSwap

        # 2. Install / update llama.cpp
        $null = Install-Or-Update-LlamaCpp

        # 3. Select model directory (drives config.yaml + opencode.json)
        $modelDir = Select-ModelDirectory

        # 4. Optional: llama-swap config.yaml (requires a model directory)
        $swapCfg = $null
        if ($modelDir) {
            $swapCfg = New-LlamaSwapConfig -ModelDir $modelDir
        }

        # 5. Optional: opencode.json (only if models were configured)
        if ($swapCfg -and $swapCfg.Models.Count -gt 0) {
            New-OpencodeConfig -BaseUrl $swapCfg.ServerBaseUrl -Models $swapCfg.Models
        }

        # 6. Create start-llama-swap.bat if config was written
        if ($swapCfg) {
            $swapExe     = Join-Path $LlamaSwapDir 'llama-swap.exe'
            $swapCfgFile = Join-Path $LlamaSwapDir 'config.yaml'
            $batFile     = Join-Path $ScriptRoot 'start-llama-swap.bat'
            $batContent  = "@echo off`r`n`"$swapExe`" --config `"$swapCfgFile`" --listen $($swapCfg.ListenAddr)`r`npause`r`n"
            Set-Content -Path $batFile -Value $batContent -Encoding ASCII -NoNewline
            Write-Ok "start-llama-swap.bat written to $batFile"
        }
    }
    finally {
        # Clean up any leftover zip files in the download staging area
        if (Test-Path $DownloadDir) {
            Get-ChildItem $DownloadDir -Filter '*.zip' -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            $remaining = Get-ChildItem $DownloadDir -ErrorAction SilentlyContinue
            if (-not $remaining) { Remove-Item $DownloadDir -Force -ErrorAction SilentlyContinue }
        }
    }

    # 7. Optional: scheduled auto-update task
    Write-Host ''
    Register-UpdateTask

    # Summary
    Write-Section 'Done'

    $swapExe     = Join-Path $LlamaSwapDir 'llama-swap.exe'
    $swapCfgFile = Join-Path $LlamaSwapDir 'config.yaml'

    Write-Ok 'Installation complete.'
    Write-Host ''

    if ($swapCfg) {
        Write-Host '  To start llama-swap, run:' -ForegroundColor DarkGray
        Write-Host "    start-llama-swap.bat" -ForegroundColor White
        Write-Host ''
        Write-Host '  Or manually:' -ForegroundColor DarkGray
        Write-Host "    `"$swapExe`" --config `"$swapCfgFile`" --listen $($swapCfg.ListenAddr)" -ForegroundColor White
    }
    else {
        Write-Host '  To start llama-swap:' -ForegroundColor DarkGray
        Write-Host "    `"$swapExe`" --config `"$swapCfgFile`" --listen <host>:<port>" -ForegroundColor White
    }

    Write-Host ''
    Write-Host '  llama-swap will listen on the address/port you configured' -ForegroundColor DarkGray
    Write-Host '  and automatically start/stop llama.cpp backends per request.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Press Enter to exit...' -NoNewline
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

Main

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

    Directories created:
      <script_root>\llama-swap\   - llama-swap binary + config
      <script_root>\llama.cpp\    - llama.cpp binaries (+ CUDA runtime if applicable)
.PARAMETER Reconfigure
    Force the full configuration wizard even if the installation is already complete.
#>
param(
    [switch]$Reconfigure
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

function Read-Confirm ([string]$Prompt) {
    $r = (Read-Host "  $Prompt (Y/n)").Trim()
    return $r -eq '' -or $r -match '^[yY]$'
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
    Write-Do "Downloading $(Split-Path -Leaf $OutFile)..."
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
    finally {
        $ProgressPreference = $prev
    }
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

function Show-BuildMenu ($Builds, [string]$CurrentBuild) {
    Write-Host '  Available llama.cpp Windows builds:' -ForegroundColor Cyan
    Write-Host ''

    $i = 1
    foreach ($b in $Builds) {
        if ($b.name -match '^llama-[^-]+-bin-win-(.+)-x64\.zip$') {
            $type = $Matches[1]
        }
        else {
            $type = $b.name
        }

        $isCuda = $type -match '^cuda-'
        $color  = if ($isCuda) { 'Green' } else { 'White' }

        if ($type -eq $CurrentBuild) {
            $marker = '  <- current'
        }
        else {
            $marker = ''
        }

        Write-Host "  [$i] " -NoNewline -ForegroundColor DarkGray
        Write-Host "$type$marker" -ForegroundColor $color
        $i++
    }

    Write-Host ''
    Write-Host '  Notes:' -ForegroundColor DarkGray
    Write-Host '  * CUDA builds (green) require an NVIDIA GPU + matching CUDA Toolkit' -ForegroundColor DarkGray
    Write-Host '  * avx2   -- recommended for most modern CPUs (Intel Haswell+ / AMD Ryzen)' -ForegroundColor DarkGray
    Write-Host '  * vulkan -- GPU acceleration via Vulkan; works on AMD, Intel, and NVIDIA' -ForegroundColor DarkGray
    Write-Host '  * avx    -- for older CPUs that lack AVX2 support' -ForegroundColor DarkGray
    Write-Host ''
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

    Show-BuildMenu -Builds $builds -CurrentBuild $currentBuild

    $idx = 0
    do {
        $selection = (Read-Host "  Select build [1-$($builds.Count)]").Trim()
        [int]::TryParse($selection, [ref]$idx) | Out-Null
    } while ($idx -lt 1 -or $idx -gt $builds.Count)

    $selected = $builds[$idx - 1]

    if ($selected.name -match '^llama-[^-]+-bin-win-(.+)-x64\.zip$') {
        $buildType = $Matches[1]
    }
    else {
        $buildType = $selected.name
    }

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

    $defaultDir = Join-Path $ScriptRoot 'models'

    Write-Host '  Where are your .gguf model files located?' -ForegroundColor Cyan
    Write-Host ''

    $useDefault = Read-Confirm "Use $defaultDir as model directory?"

    if ($useDefault) {
        if (-not (Test-Path $defaultDir)) {
            New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null
            Write-Ok "Created $defaultDir"
        }
        Write-Host ''
        Write-Host '  Please place your .gguf model files in:' -ForegroundColor Yellow
        Write-Host "    $defaultDir" -ForegroundColor White
        Write-Host ''
        Read-Host '  Press Enter when ready to scan for models'
        return $defaultDir
    }
    else {
        Write-Host ''
        $customDir = (Read-Host '  Enter model directory path (or Enter to skip config)').Trim()

        if ([string]::IsNullOrEmpty($customDir)) {
            Write-Info 'No model directory selected -- skipping config.yaml and opencode.json.'
            return $null
        }

        if (-not (Test-Path $customDir)) {
            Write-Warn "Directory not found: $customDir"
            Write-Info 'Skipping config.yaml and opencode.json.'
            return $null
        }

        return $customDir
    }
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

    $addr = (Read-Host '  Server host [localhost]').Trim()
    if ([string]::IsNullOrEmpty($addr)) { $addr = 'localhost' }

    $port = (Read-Host '  Server port [8080]').Trim()
    if ([string]::IsNullOrEmpty($port)) { $port = '8080' }

    $listenAddr    = "${addr}:${port}"
    $serverBaseUrl = "http://${addr}:${port}"

    # Configure each discovered model
    $llamaServerExe = Join-Path $LlamaCppDir 'llama-server.exe'

    Write-Host ''
    Write-Host '  Configure each model. Press Enter on optional fields to omit the flag.' -ForegroundColor Cyan
    Write-Host ''

    $models = [System.Collections.Generic.List[hashtable]]::new()
    $total  = $ggufFiles.Count

    # Ask once whether to share parameters across all models
    $sharedParams = $null
    if ($total -gt 1) {
        Write-Host ''
        $useShared = Read-Confirm 'Use the same parameters for all models?'
        if ($useShared) {
            Write-Host ''
            Write-Host '  -- Shared parameters (applied to all models) --' -ForegroundColor Yellow
            Write-Host ''

            $sCtxStr = (Read-Host '  Context window size [65536]').Trim()
            $sCtxVal = 0
            if (-not [int]::TryParse($sCtxStr, [ref]$sCtxVal) -or $sCtxVal -le 0) { $sCtxVal = 65536 }

            $sOutStr = (Read-Host '  Max output tokens for opencode [8192]').Trim()
            $sOutVal = 0
            if (-not [int]::TryParse($sOutStr, [ref]$sOutVal) -or $sOutVal -le 0) { $sOutVal = 8192 }

            $sFullGpu    = Read-Confirm 'Load all models fully on GPU (--gpu-layers 999)?'
            $sTempStr    = (Read-Host '  Temperature      (Enter to omit)').Trim()
            $sTopPStr    = (Read-Host '  Top_P            (Enter to omit)').Trim()
            $sTopKStr    = (Read-Host '  Top_K            (Enter to omit)').Trim()
            $sMinPStr    = (Read-Host '  Min_P            (Enter to omit)').Trim()
            $sRepPenStr  = (Read-Host '  Repeat Penalty   (Enter to omit)').Trim()
            $sPresPenStr = (Read-Host '  Presence Penalty (Enter to omit)').Trim()

            $sharedParams = @{
                CtxVal   = $sCtxVal;  OutVal      = $sOutVal
                FullGpu  = $sFullGpu; TempStr     = $sTempStr
                TopPStr  = $sTopPStr; TopKStr     = $sTopKStr
                MinPStr  = $sMinPStr; RepPenStr   = $sRepPenStr
                PresPenStr = $sPresPenStr
            }
            Write-Host ''
        }
    }

    $idx = 1
    foreach ($file in $ggufFiles) {
        $name      = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $modelPath = $file.FullName

        Write-Host "  -- Model $idx/$total : $name" -ForegroundColor Yellow
        Write-Host ''

        if ($sharedParams) {
            # Use the shared parameters collected above
            $ctxVal     = $sharedParams.CtxVal
            $outVal     = $sharedParams.OutVal
            $fullGpu    = $sharedParams.FullGpu
            $tempStr    = $sharedParams.TempStr
            $topPStr    = $sharedParams.TopPStr
            $topKStr    = $sharedParams.TopKStr
            $minPStr    = $sharedParams.MinPStr
            $repPenStr  = $sharedParams.RepPenStr
            $presPenStr = $sharedParams.PresPenStr
        }
        else {
            # Prompt individually for this model
            $ctxStr = (Read-Host '  Context window size [65536]').Trim()
            $ctxVal = 0
            if (-not [int]::TryParse($ctxStr, [ref]$ctxVal) -or $ctxVal -le 0) { $ctxVal = 65536 }

            $outStr = (Read-Host '  Max output tokens for opencode [8192]').Trim()
            $outVal = 0
            if (-not [int]::TryParse($outStr, [ref]$outVal) -or $outVal -le 0) { $outVal = 8192 }

            $fullGpu    = Read-Confirm 'Load model fully on GPU (--gpu-layers 999)?'
            $tempStr    = (Read-Host '  Temperature      (Enter to omit)').Trim()
            $topPStr    = (Read-Host '  Top_P            (Enter to omit)').Trim()
            $topKStr    = (Read-Host '  Top_K            (Enter to omit)').Trim()
            $minPStr    = (Read-Host '  Min_P            (Enter to omit)').Trim()
            $repPenStr  = (Read-Host '  Repeat Penalty   (Enter to omit)').Trim()
            $presPenStr = (Read-Host '  Presence Penalty (Enter to omit)').Trim()
        }

        # Build the launch command
        $cmd = "$llamaServerExe -m `"$modelPath`" --port `${PORT} --ctx-size $ctxVal --jinja --flash-attn on"

        if ($fullGpu)                                    { $cmd += ' --gpu-layers 999' }
        if (-not [string]::IsNullOrEmpty($tempStr))      { $cmd += " --temp $tempStr" }
        if (-not [string]::IsNullOrEmpty($topPStr))      { $cmd += " --top-p $topPStr" }
        if (-not [string]::IsNullOrEmpty($topKStr))      { $cmd += " --top-k $topKStr" }
        if (-not [string]::IsNullOrEmpty($minPStr))      { $cmd += " --min-p $minPStr" }
        if (-not [string]::IsNullOrEmpty($repPenStr))    { $cmd += " --repeat-penalty $repPenStr" }
        if (-not [string]::IsNullOrEmpty($presPenStr))   { $cmd += " --presence-penalty $presPenStr" }

        $models.Add(@{ Name = $name; Cmd = $cmd; ContextLimit = $ctxVal; OutputLimit = $outVal })
        Write-Ok "Configured: $name"
        Write-Info "  cmd: $cmd"
        Write-Host ''
        $idx++
    }

    # Build the YAML manually (avoids requiring a YAML module)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('healthCheckTimeout: 60')
    [void]$sb.AppendLine('globalTTL: 600')
    [void]$sb.AppendLine('startPort: 8081')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('models:')

    if ($models.Count -eq 0) {
        [void]$sb.AppendLine('  # No models defined -- add entries like the example below:')
        [void]$sb.AppendLine('  # my-model:')
        $exampleCmd = "$LlamaCppDir\llama-server.exe -m `"C:\models\model.gguf`" --port `${PORT} --ctx-size 65536 --jinja --flash-attn on --gpu-layers 999"
        [void]$sb.AppendLine("  #   cmd: '$exampleCmd'")
    }
    else {
        foreach ($m in $models) {
            # YAML single-quoted strings: escape any literal single quotes by doubling them
            $yamlCmd = $m.Cmd -replace "'", "''"
            [void]$sb.AppendLine("  $($m.Name):")
            [void]$sb.AppendLine("    cmd: '$yamlCmd'")
        }
    }

    if (-not (Test-Path $LlamaSwapDir)) {
        New-Item -ItemType Directory -Path $LlamaSwapDir -Force | Out-Null
    }

    Set-Content -Path $configPath -Value $sb.ToString() -Encoding UTF8
    Write-Ok "config.yaml written to $configPath"

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
# Main
# -------------------------------------------------------------------------------

function Main {
    Write-Banner

    Write-Info "Script root : $ScriptRoot"
    Write-Info "llama-swap  : $LlamaSwapDir"
    Write-Info "llama.cpp   : $LlamaCppDir"

    if (-not (Test-Path $DownloadDir)) {
        New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
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
    Read-Host '  Press Enter to exit'
}

Main

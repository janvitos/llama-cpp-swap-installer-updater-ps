# llama-swap + llama.cpp  |  Bootstrap Installer
#
# Usage (run in PowerShell as administrator or standard user):
#   irm https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/get.ps1 | iex
#
# To reconfigure an existing install, run install.bat --reconfigure
# from the directory you chose below.

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# -------------------------------------------------------------------------------
# UPDATE THIS to your actual GitHub raw base URL before publishing
# -------------------------------------------------------------------------------
$RepoRaw = 'https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main'
# -------------------------------------------------------------------------------

$sep = '-' * 60
Write-Host ''
Write-Host $sep -ForegroundColor DarkCyan
Write-Host '  llama-swap + llama.cpp  |  Bootstrap Installer' -ForegroundColor Cyan
Write-Host $sep -ForegroundColor DarkCyan
Write-Host ''

# Choose install directory
$defaultDir = Join-Path $env:USERPROFILE 'llama-installer'
$inputDir   = (Read-Host "  Install directory [$defaultDir]").Trim()
if ([string]::IsNullOrEmpty($inputDir)) { $inputDir = $defaultDir }

if (-not (Test-Path $inputDir)) {
    New-Item -ItemType Directory -Path $inputDir -Force | Out-Null
    Write-Host "  [OK] Created $inputDir" -ForegroundColor Green
}
else {
    Write-Host "  [OK] Using $inputDir" -ForegroundColor Green
}

Write-Host ''
Write-Host '  [>>] Downloading installer files...' -ForegroundColor Cyan

$files = @('install.ps1', 'install.bat')
foreach ($file in $files) {
    $dest = Join-Path $inputDir $file
    try {
        Invoke-WebRequest -Uri "$RepoRaw/$file" -OutFile $dest -UseBasicParsing
        Write-Host "  [OK] $file" -ForegroundColor Green
    }
    catch {
        Write-Host "  [XX] Failed to download $file : $_" -ForegroundColor Red
        Write-Host '       Check that the repo URL in get.ps1 is correct and the repo is public.' -ForegroundColor Yellow
        return
    }
}

Write-Host ''
Write-Host '  [>>] Launching installer...' -ForegroundColor Cyan
Write-Host ''

& (Join-Path $inputDir 'install.ps1')

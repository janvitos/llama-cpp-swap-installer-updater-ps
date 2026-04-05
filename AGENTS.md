# AGENTS.md — Guide for AI Agents

This file documents the project structure, conventions, and key rules for AI agents working on this codebase.

---

## Project Overview

A PowerShell 5.1 installer/updater for [llama.cpp](https://github.com/ggml-org/llama.cpp) and [llama-swap](https://github.com/mostlygeek/llama-swap) on Windows. Two entry-point files:

| File | Purpose |
|---|---|
| `get.ps1` | Bootstrap: prompts for install directory, downloads `install.ps1` + `install.bat`, launches the installer |
| `install.ps1` | Main script: full install wizard, update-only mode, `--reconfigure`, `--scan` |
| `install.bat` | Thin wrapper that calls `install.ps1` with any arguments passed to it |

---

## Compatibility Constraint

**Target: PowerShell 5.1 on Windows 10/11.** This is the version shipped with Windows — do not use features from PS 6+/7+ (e.g. `??`, `?.`, ternary `? :`, `ForEach-Object -Parallel`). The script starts with `#Requires -Version 5.1`.

Other constraints:
- No external modules or dependencies — only what ships with Windows.
- `ConvertFrom-Json` returns `PSCustomObject`, not `[hashtable]` — access fields with dot notation, cast explicitly when needed.
- `Set-StrictMode -Version Latest` is active — all variables must be declared before use.

---

## Script Structure (`install.ps1`)

Functions are defined in this order:

### Console helpers
| Function | Purpose |
|---|---|
| `Write-Banner` | Prints the title header |
| `Write-Section` | Prints a section divider with a label |
| `Write-Ok` / `Write-Info` / `Write-Warn` / `Write-Do` | Styled status line output |
| `Read-Confirm` | Y/N prompt with a configurable default (`-Default $true` = Y) |
| `Read-OptionalParam` | Prompt for an optional string with a saved default; enter `-` to clear |

### GitHub API
| Function | Purpose |
|---|---|
| `Get-LatestRelease` | Fetches the latest GitHub release object for a given `owner/repo` |

### Settings persistence
All user choices are saved to `settings.json` in the script root after each wizard run.

| Function | Purpose |
|---|---|
| `Read-Settings` | Returns a hashtable with all settings, merged with hardcoded defaults |
| `Save-Settings ([hashtable]$Updates)` | Merges `$Updates` into the current settings and writes `settings.json` |

`Read-Settings` always returns a complete hashtable — callers can rely on all keys being present. `Save-Settings` takes a **hashtable**, not named parameters — call it as `Save-Settings @{ Key = Value }`.

The `Params` key is a nested hashtable containing all model generation parameters:
`CtxVal`, `OutVal`, `FullGpu`, `TempStr`, `TopPStr`, `TopKStr`, `MinPStr`, `RepPenStr`, `PresPenStr`.

### Version tracking
Each installed component directory (`llama.cpp\`, `llama-swap\`) contains a `.version` file with the release tag. `llama.cpp\` also has a `.buildtype` file with the build variant string (e.g. `avx2`, `cuda-12.4`).

### Download + extract
| Function | Purpose |
|---|---|
| `Invoke-Download` | Downloads a file with a progress bar. Uses `WebClient.DownloadFileTaskAsync` (native speed) + file-size polling every 200 ms |
| `Expand-ToDir` | Extracts a zip, flattening one level of nesting if the zip contains a single top-level folder |

### Binary install/update
| Function | Purpose |
|---|---|
| `Install-Or-Update-LlamaSwap` | Downloads and installs/updates the llama-swap binary |
| `Install-Or-Update-LlamaCpp` | Downloads and installs/updates llama.cpp; prompts for build variant via interactive arrow-key menu |
| `Get-WindowsBuilds` | Filters GitHub release assets to Windows x64 zips |
| `Get-CudartAsset` | Finds the matching CUDA runtime zip for a given CUDA version |
| `Select-Build` | Interactive arrow-key menu for choosing a llama.cpp build variant |

### Configuration wizard
| Function | Purpose |
|---|---|
| `Select-ModelDirectory` | Prompts for the `.gguf` model folder, with saved default |
| `Read-ModelParams` | Prompts for all model generation parameters, with saved defaults |
| `Read-OptionalParam` | Used inside `Read-ModelParams` for optional sampler fields |
| `Build-ModelEntry` | Builds a single model config hashtable (name, path, cmd string) |
| `Write-SwapConfig` | Writes `llama-swap\config.yaml` from a list of model entries |
| `New-LlamaSwapConfig` | Full config wizard: listen address, model params, calls above helpers |
| `New-OpencodeConfig` | Writes `opencode.json` to `%USERPROFILE%\.config\opencode\` |

### Scan mode (`--scan` / `-Scan`)
| Function | Purpose |
|---|---|
| `Parse-CmdString` | Parses a llama-server command string back into a params hashtable |
| `Read-ConfigModels` | Reads existing model entries from `config.yaml` |
| `Read-OpencodeModels` | Reads existing model entries from `opencode.json` |
| `Read-ExistingListenAddr` | Reads the listen address from `start-llama-swap.bat` |
| `Show-DefaultParams` | Displays saved params for user confirmation during scan |
| `Invoke-Scan` | Diffs current `.gguf` files against existing config, handles added/removed models |

### Scheduled task
| Function | Purpose |
|---|---|
| `Register-UpdateTask` | Offers to create a Windows Task Scheduler task that runs the updater daily at 03:00 and at login |

The task is created via `schtasks.exe /Create /XML` using a hand-authored XML template — this gives full control over every setting. Key settings: `InteractiveToken` logon (runs when user is logged on, no admin required), `StartWhenAvailable` (run ASAP after missed start), `AllowHardTerminate` (force stop), `DisallowStartIfOnBatteries false`.

### Entry point
`Main` — orchestrates all modes: scan-only, update-only, full install/reconfigure.

---

## Conventions

- **Output**: always use `Write-Ok`, `Write-Info`, `Write-Warn`, `Write-Do` — never bare `Write-Host` for status messages (except inside UI helpers).
- **Prompts**: use `Read-Confirm` for Y/N, `Read-OptionalParam` for optional strings with saved defaults, `Read-Host` for required string input.
- **Saved settings**: any value the user is prompted for must be persisted via `Save-Settings` and pre-filled from `Read-Settings` on next run.
- **Error handling**: `$ErrorActionPreference = 'Stop'` is global. Use `try/catch` where you want to handle or suppress errors. Do not silently swallow exceptions without a good reason.
- **No external dependencies**: do not add `Install-Module`, NuGet packages, or any other dependency.

---

## Files Not in the Repo (generated at install time)

These are in `.gitignore` and must never be committed:

| File/Dir | Description |
|---|---|
| `settings.json` | Persisted user settings |
| `start-llama-swap.bat` | Generated launcher (contains absolute paths + listen address) |
| `llama.cpp\` | Downloaded binaries |
| `llama-swap\` | Downloaded binary + generated `config.yaml` |
| `.claude\` | Claude Code session data |

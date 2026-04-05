# llama-swap + llama.cpp Installer / Updater

A PowerShell wizard that downloads, installs, and configures [llama-swap](https://github.com/mostlygeek/llama-swap) and [llama.cpp](https://github.com/ggml-org/llama.cpp) on Windows — and keeps them up to date with a single command.

---

## What it does

**First run** — walks you through a full setup wizard:

- Downloads the latest **llama-swap** and **llama.cpp** Windows binaries from GitHub Releases
- Lets you choose a llama.cpp build (AVX2, AVX, Vulkan, CUDA, ...)
- Scans a folder of your choice for `.gguf` model files
- Generates a `config.yaml` for llama-swap with a `llama-server` command for each model
- Generates an `opencode.json` so [opencode](https://opencode.ai) connects to llama-swap automatically
- Creates a `start-llama-swap.bat` launcher

**Subsequent runs** — detects an existing install and silently updates the binaries only. No prompts, safe to schedule as a background task.

**`--reconfigure` flag** — forces the full wizard to run again without reinstalling from scratch.

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later (included with Windows)
- Internet connection (for downloading binaries from GitHub)
- `.gguf` model files (if you want to configure llama-swap)

For CUDA builds of llama.cpp: an NVIDIA GPU and the [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads) installed.

---

## Quick Install

Run this in a PowerShell window:

```powershell
irm https://raw.githubusercontent.com/janvitos/llama-cpp-swap-installer-updater-ps/main/get.ps1 | iex
```

You will be prompted for an install directory (default: `%USERPROFILE%\llama-installer`). The installer downloads to that folder and launches immediately.

---

## Manual Install

1. Download `install.ps1` and `install.bat` from this repo.
2. Place both files in the same folder.
3. Double-click `install.bat` — or run in PowerShell:
   ```powershell
   .\install.ps1
   ```

---

## Updating

Re-run `install.bat` (or `install.ps1`) at any time. If the installation is already configured, the script runs in **update-only mode** — it checks for new releases of llama-swap and llama.cpp and downloads them if available, then exits silently.

---

## Reconfiguring

To redo the full setup wizard (change model directory, rebuild config.yaml, etc.):

```bat
install.bat --reconfigure
```

Or in PowerShell:

```powershell
.\install.ps1 -Reconfigure
```

---

## Directory Layout

After a full install, your chosen directory will look like this:

```
<install dir>\
    install.ps1
    install.bat
    start-llama-swap.bat        <- double-click to start llama-swap
    llama-swap\
        llama-swap.exe
        config.yaml
        .version
    llama.cpp\
        llama-server.exe
        (+ other llama.cpp binaries and DLLs)
        .version
```

`config.yaml` and `opencode.json` are generated during the wizard and can be updated by running with `--reconfigure`.

---

## llama-swap config.yaml

The wizard scans your model directory for `.gguf` files and builds a `config.yaml` entry for each one, including:

- Context window size
- GPU offloading (`--gpu-layers 999`)
- Sampling parameters (temperature, top_p, top_k, min_p, repeat penalty, presence penalty)

You can apply the same parameters to all models at once, or configure each one individually.

---

## opencode.json

If you use [opencode](https://opencode.ai), the wizard writes an `opencode.json` to `%USERPROFILE%\.config\opencode\opencode.json` that registers llama-swap as an OpenAI-compatible provider, with each model's context and output limits pre-filled.

---

## License

[MIT](LICENSE)

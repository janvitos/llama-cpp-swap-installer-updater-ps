# ⚡ llama.cpp + llama-swap Installer / Updater

A PowerShell wizard that downloads, installs, and configures [llama.cpp](https://github.com/ggml-org/llama.cpp) and [llama-swap](https://github.com/mostlygeek/llama-swap) on Windows — and keeps them up to date with a single command.

---

## ✨ What it does

**First run** — walks you through a full setup wizard:

- 📦 Downloads the latest **llama.cpp** and **llama-swap** Windows binaries from GitHub Releases
- 🔧 Lets you choose a llama.cpp build (AVX2, AVX, Vulkan, CUDA, ...)
- 🔍 Scans a folder of your choice for `.gguf` model files
- 📝 Generates a `config.yaml` for llama-swap with a `llama-server` command for each model
- 🔗 Generates an `opencode.json` so [opencode](https://opencode.ai) connects to llama-swap automatically
- 🚀 Creates a `start-llama-swap.bat` launcher

**Subsequent runs** — detects an existing install and silently updates the binaries only. No prompts, safe to schedule as a background task.

**`--reconfigure` flag** — forces the full wizard to run again without reinstalling from scratch.

---

## 🖥️ Requirements

- Windows 10 / 11
- PowerShell 5.1 or later (included with Windows)
- Internet connection (for downloading binaries from GitHub)
- `.gguf` model files (if you want to configure llama-swap)

> For CUDA builds of llama.cpp: an NVIDIA GPU with up-to-date drivers is required. The necessary CUDA runtime DLLs are downloaded automatically alongside the build — no separate CUDA Toolkit installation needed.

---

## 🚀 Quick Install

Run this in a PowerShell window:

```powershell
irm https://raw.githubusercontent.com/janvitos/llama-cpp-swap-installer-updater-ps/main/get.ps1 | iex
```

You will be prompted for an install directory (default: `%USERPROFILE%\llama-installer`). The installer downloads to that folder and launches immediately.

---

## 🔧 Manual Install

1. Download `install.ps1` and `install.bat` from this repo.
2. Place both files in the same folder.
3. Double-click `install.bat` — or run in PowerShell:
   ```powershell
   .\install.ps1
   ```

---

## 🔄 Updating

Re-run `install.bat` (or `install.ps1`) at any time. If the installation is already configured, the script runs in **update-only mode** — it checks for new releases of llama.cpp and llama-swap and downloads them if available, then exits silently.

---

## ⚙️ Reconfiguring

To redo the full setup wizard (change model directory, rebuild `config.yaml`, etc.):

```bat
install.bat --reconfigure
```

Or in PowerShell:

```powershell
.\install.ps1 -Reconfigure
```

---

## 🔍 Rescanning Models

When you add or remove `.gguf` files, regenerate `config.yaml` and `opencode.json` without touching the binaries:

```bat
install.bat --scan
```

Or in PowerShell:

```powershell
.\install.ps1 -Scan
```

---

## 🕐 Automatic Updates

At the end of the setup wizard, you will be offered the option to create a **Windows Task Scheduler** task that runs the updater silently in the background — once daily (at 03:00) and at every login. The task runs whether or not you are logged in and does not store your password.

To remove the task later, open **Task Scheduler** and delete the task named `llama-cpp-swap-updater`, or run:

```powershell
Unregister-ScheduledTask -TaskName 'llama-cpp-swap-updater' -Confirm:$false
```

---

## 💾 Saved Settings

After the first run, all your choices (install directory, model folder, listen host/port, and all model parameters) are saved to `settings.json` in the install directory. Subsequent runs — including `--reconfigure` and `--scan` — pre-fill every prompt with your previous values so you only need to press Enter to keep them.

---

## 📁 Directory Layout

After a full install, your chosen directory will look like this:

```
<install dir>\
    install.ps1
    install.bat
    settings.json               <- saved settings (auto-generated)
    start-llama-swap.bat        <- double-click to start llama-swap
    llama.cpp\
        llama-server.exe
        (+ other llama.cpp binaries and DLLs)
        .version
    llama-swap\
        llama-swap.exe
        config.yaml
        .version
```

`config.yaml` and `opencode.json` are generated during the wizard and can be updated by running with `--reconfigure`.

---

## 🤖 llama-swap config.yaml

The wizard scans your model directory for `.gguf` files and builds a `config.yaml` entry for each one, including:

- Context window size
- GPU offloading (`--gpu-layers 999`)
- Sampling parameters (temperature, top_p, top_k, min_p, repeat penalty, presence penalty)

You can apply the same parameters to all models at once, or configure each one individually.

---

## 🔗 opencode.json

If you use [opencode](https://opencode.ai), the wizard writes an `opencode.json` to `%USERPROFILE%\.config\opencode\opencode.json` that registers llama-swap as an OpenAI-compatible provider, with each model's context and output limits pre-filled.

---

## 📄 License

[MIT](LICENSE)

# ComfyUI ROCmRoll

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078d7.svg)](https://www.microsoft.com/windows)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](https://github.com/PowerShell/PowerShell)
[![AMD ROCm](https://img.shields.io/badge/AMD-ROCm-ED1C24.svg)](https://rocm.docs.amd.com)

ComfyUI ROCmRoll is a Windows platform manager for creating, launching, updating, diagnosing, and repairing portable ComfyUI installations optimized for AMD GPUs with ROCm packages.

ROCmRoll keeps its orchestration outside ComfyUI:

- ROCmRoll owns runtimes, environments, caches, manifests, state, logs, launchers, diagnostics, repair flows, and package installation.
- Each ComfyUI instance owns its checkout, instance-local `custom_nodes`, generated configuration, and instance metadata.
- Heavy assets such as models, input, output, temp files, and optional workflows are shared outside the ComfyUI source tree.

See [docs/architecture.md](docs/architecture.md) for the implementation architecture.

## Status

This repository contains the active PowerShell implementation.

Implemented areas include:

- Thin `rocmroll.bat` wrapper around `source\rocmroll.ps1`
- Full install orchestration through PowerShell modules
- Python 3.12.10 runtime creation from embeddable Python plus full ZIP enrichment
- Per-instance Python environments
- AMD GPU detection with manual `--gfx` override
- Stable, preview, nightly, RDNA1, and RDNA2 channel manifests
- ComfyUI Git mirror cache and per-instance clone
- Instance-local custom node install/update
- Generated `extra_model_paths.yaml`
- Generated launchers under `launchers\`
- Shared asset folders
- ROCm/PyTorch validation via `source\scripts\validate-rocm.py`
- Registry-driven `instance`, `doctor`, `env`, `rocm`, `comfyui`, `cache`, `state`, `logs`, `config`, `profile`, `patch`, and `workspace` command families
- JSON state files, human logs, JSONL logs, and PID lock files
- Optional ComfyUI Desktop registration
- User configuration through `rocmroll.ini`
- Named workspaces for path sets
- Execution profiles for environment variables and ComfyUI launch arguments

## Requirements

ROCmRoll targets:

- Windows only
- PowerShell 5.1 or newer
- Git available in `PATH`
- An AMD Radeon, Radeon Pro, or Instinct GPU mapped in `source\manifests\rocm-architectures.json`, or a manual `--gfx` override
- AMD graphics driver installed
- Long path support enabled in Windows, strongly recommended
- An ASCII-only install path, recommended
- Network access to Python, PyPI, GitHub, AMD ROCm package endpoints, and ROCm nightly indexes
- Enough disk space for Python runtimes, ComfyUI checkouts, ROCm/PyTorch wheels, caches, models, and outputs

Unsupported by design:

- Linux, WSL, and macOS
- NVIDIA and Intel GPU backends
- Global custom node sharing across all instances
- Silent modification of ComfyUI source files outside managed patches

## Quick Start

Run commands from the repository root:

```powershell
cd C:\Platform\ai
```

Initialize the folder layout:

```powershell
.\rocmroll.bat init
```

Check the host system:

```powershell
.\rocmroll.bat doctor --system
.\rocmroll.bat doctor --gpu
```

Create a stable ComfyUI instance:

```powershell
.\rocmroll.bat instance install --name rocm-stable --channel stable
```

Launch it:

```powershell
.\rocmroll.bat instance launch --name rocm-stable
```

The generated launcher starts ComfyUI on:

```text
http://127.0.0.1:8188
```

Use a different port at launch time:

```powershell
.\rocmroll.bat instance launch --name rocm-stable --port 8189
```

If more than one ready instance exists, `instance launch` can run without `--name` and ROCmRoll will show an interactive selector:

```powershell
.\rocmroll.bat launch
```

## Custom Resources

ROCmRoll supports per-instance resource overlays in the `custom\` folder at the repository root. Files placed there are loaded after the global manifests and do not require editing any source file.

### Layout

```text
custom\
  <instanceName>\
    requirements.txt      Optional extra pip packages for this instance
    custom_nodes.json     Optional extra custom nodes for this instance
```

### Custom requirements

Place a standard `requirements.txt` in `custom\<instanceName>\`:

```text
custom\rocm-stable\requirements.txt
```

ROCmRoll installs it after ComfyUI's own `requirements.txt` using the same pip cache and upgrade strategy. A non-zero pip exit code is a fatal error and reports `ROCMROLL-COMFY-005`.

This file is picked up by every code path that runs ComfyUI dependency installation:

- `instance install`
- `comfyui requirements`
- `instance update --comfyui`
- `instance repair --comfyui`

### Custom nodes

Place a `custom_nodes.json` in `custom\<instanceName>\` using the same format as `source\manifests\custom-nodes.json`:

```json
{
  "default": [
    {
      "name": "MyCustomNode",
      "repo": "https://github.com/user/MyCustomNode.git",
      "ref": "main",
      "installRequirements": true
    }
  ]
}
```

ROCmRoll clones and configures these nodes after the default manifest nodes. Clone failures are non-fatal warnings. The list is processed by every code path that handles custom nodes:

- `instance install`
- `comfyui nodes --install` / `--update`
- `instance repair --custom-nodes`

The `custom\` folder is root-relative and is not user-configurable in `rocmroll.ini`.

## Channels

Channels are defined in `source\manifests\channels.json`.

| Channel | ComfyUI ref | ROCm source | Default profile | Notes |
| --- | --- | --- | --- | --- |
| `stable` | `v0.25.0` | AMD ROCm 7.2.1 direct URLs | `stable` | Pinned ROCmRoll baseline; Python 3.12 required |
| `preview` | `master` | `https://rocm.nightlies.amd.com/v2/<rocmIndex>/` | `optimized` | Promoted nightly index |
| `nightly` | `master` | `https://rocm.nightlies.amd.com/v2-staging/<rocmIndex>/` | `optimized` | Cutting-edge staging index |
| `rdna1` | `v0.25.0` | `https://rocm.nightlies.amd.com/v2/<rocmIndex>/` | `stable` | Experimental RDNA 1 support |
| `rdna2` | `v0.25.0` | `https://rocm.nightlies.amd.com/v2-staging/<rocmIndex>/` | `stable` | Experimental RDNA 2 support |

Stable currently installs:

- Python `3.12.10`
- ROCm `7.2.1`
- torch `2.9.1+rocm7.2.1`
- torchvision `0.24.1+rocm7.2.1`
- torchaudio `2.9.1+rocm7.2.1`

`preview` and `nightly` install `torch`, `torchvision`, `torchaudio`, and `rocm[libraries,devel]` from AMD ROCm indexes. `nightly` is more volatile because it uses the staging index.

### RDNA 1 And RDNA 2

RDNA 1 (`gfx101X`) and RDNA 2 (`gfx103X`) are experimental on Windows ROCm. AMD has no official Windows ROCm stable release wheels for these GPU families, so ROCmRoll uses dedicated index-based channels.

When `--channel stable` is selected and ROCmRoll detects RDNA 1 or RDNA 2, it automatically switches channels:

| GPU family | Auto-selected channel |
| --- | --- |
| `gfx101X` | `rdna1` |
| `gfx103X` | `rdna2` |

You can also select them explicitly:

```powershell
.\rocmroll.bat instance install --name my-rdna1 --channel rdna1
.\rocmroll.bat instance install --name my-rdna2 --channel rdna2
```

## Profiles

Execution profiles are JSON presets that control process-local environment variables and ComfyUI launch arguments. The active profile is loaded by the generated launcher at runtime, so you can switch behavior without reinstalling.

Profiles live in `profiles\` by default. The folder is configurable through `rocmroll.ini`.

| Profile file | Profile | Default channel | Summary |
| --- | --- | --- | --- |
| `stable.json` | `stable` | `stable`, `rdna1`, `rdna2` | Baseline AMD profile with minimal env vars |
| `stable-dynamic-vram.json` | `stable-dynamic-vram` | none | Baseline plus `--enable-dynamic-vram` |
| `optimized.json` | `optimized` | `preview`, `nightly` | Flash-Attention Triton, MIOpen settings, SageAttention, dynamic VRAM |
| `performance-autotune.json` | `performance-autotune` | none | Aggressive MIOpen and Triton autotuning |
| `experimental.json` | local experimental content | none | Check file contents before using; it currently contains an object named `optimized` |

Profile commands:

```powershell
.\rocmroll.bat profile list
.\rocmroll.bat profile show --name optimized
.\rocmroll.bat profile create --name my-profile
.\rocmroll.bat profile remove --name my-profile
```

Use a profile at install time:

```powershell
.\rocmroll.bat instance install --name rocm-stable --profile stable-dynamic-vram
```

Override a profile at launch time:

```powershell
.\rocmroll.bat instance launch --name rocm-stable --profile performance-autotune
```

Regenerate launchers with a different default profile:

```powershell
.\rocmroll.bat instance repair --name rocm-stable
```

Profile JSON shape:

```json
{
  "name": "my-profile",
  "description": "Description shown in profile list",
  "version": "1.0",
  "defaultForChannels": [],
  "env": {
    "COMFYUI_ENABLE_MIOPEN": "0"
  },
  "launchArgs": [
    "--disable-smart-memory",
    "--use-sage-attention"
  ],
  "legacyGpuOverrides": {
    "env": {
      "TORCH_BACKENDS_CUDA_MATH_SDP_ENABLED": "1"
    },
    "launchArgs": [
      "--use-quad-cross-attention"
    ]
  }
}
```

## Supported GPU Families

GPU mapping lives in `source\manifests\rocm-architectures.json`.

| GFX family | ROCm index | Architecture | Status |
| --- | --- | --- | --- |
| `gfx120X` | `gfx120X-all` | RDNA 4 | Supported |
| `gfx1150` | `gfx1150` | RDNA 3.5 / Strix Point | Supported |
| `gfx1151` | `gfx1151` | RDNA 3.5 / Strix Halo | Supported |
| `gfx1152` | `gfx1152` | RDNA 3.5 / Krackan Point | Supported |
| `gfx1153` | `gfx1153` | RDNA 3.5 | Supported |
| `gfx110X` | `gfx110X-all` | RDNA 3 | Supported |
| `gfx103X` | `gfx103X-all` | RDNA 2 | Experimental |
| `gfx101X` | `gfx101X-dgpu` | RDNA 1 | Experimental |
| `gfx90X` | `gfx90X-dcgpu` | Radeon Pro VII | Supported |
| `gfx94X` | `gfx94X-dcgpu` | MI300 / MI325 | Supported |
| `gfx950` | `gfx950-dcgpu` | MI350 / MI355 | Supported |

Manual override example:

```powershell
.\rocmroll.bat instance install --name rocm-stable --gfx gfx120X
```

## What Install Does

The full install command:

```powershell
.\rocmroll.bat instance install --name rocm-stable --channel stable
```

performs this high-level flow:

1. Initializes folder structure and cache folders.
2. Creates or reuses the Python runtime.
3. Creates or reuses the per-instance Python environment.
4. Detects the AMD GPU and resolves the ROCm index.
5. Installs ROCm/PyTorch packages for the selected channel.
6. Clones or updates the ComfyUI instance from the Git mirror cache.
7. Installs ComfyUI `requirements.txt`.
8. Generates `extra_model_paths.yaml`.
9. Optionally links workflows to `shared\workflows`.
10. Installs default custom nodes.
11. Installs the `rocm-performance` package profile.
12. Applies applicable ComfyUI source patches.
13. Generates launchers.
14. Binds the instance path into the environment `_pth` file.
15. Writes instance and environment state.
16. Registers the instance in ComfyUI Desktop if Desktop is present.
17. Runs validation.

Re-running the same install is intended to converge the instance to the requested state and reuse caches.

## Project Layout

Source and documentation:

```text
rocmroll.bat                    Thin Windows wrapper
source\rocmroll.ps1            Main CLI entrypoint
source\modules\                PowerShell modules
source\scripts\                Helper scripts
source\manifests\              Channel, runtime, GPU, package, and node manifests
source\patches\                Package and ComfyUI patch definitions
source\templates\              Generated launcher and config templates
profiles\                      Execution profile JSON files
workspaces\                    Workspace JSON files
docs\architecture.md           Current architecture reference
```

Generated runtime layout:

```text
rocmroll.ini                   Optional user configuration
.cache\                        Download, pip, Git, wheelhouse, checksum, and tool caches
.state\                        Runtime, environment, instance, patch, lock, and global state
.temp\                         Temporary extraction/work folder
environments\                  Per-instance Python environments
instances\                     Per-instance ComfyUI checkouts
launchers\                     Generated .ps1 and .bat launchers
logs\                          Install, launch, update, doctor, and crash logs
runtimes\                      Shared Python runtimes
shared\input\                  Shared ComfyUI input
shared\output\                 Shared ComfyUI output
shared\temp\                   Shared ComfyUI temp
shared\user\                   Shared user-data root
shared\models\                 Shared model storage
shared\workflows\              Optional shared workflows target
```

## Configuration

ROCmRoll reads optional configuration from `rocmroll.ini`.

Create the file with defaults commented out:

```powershell
.\rocmroll.bat config init
```

Show resolved paths:

```powershell
.\rocmroll.bat config show
```

Supported `[paths]` keys:

| Key | Default | Purpose |
| --- | --- | --- |
| `shared` | `shared` | Shared input, output, temp, user, models, workflows |
| `userdata` | `shared\user` | ComfyUI user-data root |
| `instances` | `instances` | ComfyUI checkouts |
| `environments` | `environments` | Python environments |
| `runtimes` | `runtimes` | Python runtimes |
| `launchers` | `launchers` | Generated launchers |
| `profiles` | `profiles` | Execution profiles |
| `logs` | `logs` | Logs |
| `state` | `.state` | State, locks, patch backups |
| `cache` | `.cache` | Download and package caches |

Example:

```ini
[paths]
shared       = D:\comfy\shared
instances    = D:\comfy\instances
environments = D:\comfy\environments
cache        = D:\.cache\rocmroll
```

Relative paths are resolved from the ROCmRoll root folder. Source files and `workspaces\` remain root-relative and are not redirectable.

## Workspaces

A workspace is a named set of path overrides stored in `workspaces\<name>.json`.

Path precedence:

1. `--workspace NAME` on the command line
2. Active workspace from `[active]` in `rocmroll.ini`
3. `[paths]` in `rocmroll.ini`
4. Built-in defaults

`instance list --all` is the exception used for inventory: it resolves the base `[paths]` configuration without the active workspace, then resolves every named workspace once. `--all` and `--workspace` cannot be combined.

Use a workspace for one command without changing the active workspace:

```powershell
.\rocmroll.bat instance install --name rocm-stable --workspace staging
.\rocmroll.bat doctor --instance rocm-stable --workspace production
.\rocmroll.bat instance launch --name rocm-stable --workspace staging
```

Workspace commands:

```powershell
.\rocmroll.bat workspace list
.\rocmroll.bat workspace show --name staging
.\rocmroll.bat workspace create --name staging
.\rocmroll.bat workspace use --name staging
.\rocmroll.bat workspace edit --name staging
.\rocmroll.bat workspace remove --name staging
.\rocmroll.bat workspace init --name staging
```

## Command Reference

Get help:

```powershell
.\rocmroll.bat help
.\rocmroll.bat help instance install
.\rocmroll.bat instance install --help
.\rocmroll.bat help options
```

Common commands:

| Command | Purpose |
| --- | --- |
| `instance install` | Full install: runtime, environment, ROCm/PyTorch, ComfyUI, custom nodes, packages, launchers |
| `instance launch` | Launch a ready instance |
| `instance update` | Refresh all components, or selected environment, ROCm, and ComfyUI components |
| `doctor` | Run diagnostics and health checks |
| `instance repair` | Repair all components or an explicit component scope, including managed patches |
| `instance list` | List installed instances in one workspace or all workspaces |
| `instance remove` | Remove a complete instance or an explicit component scope |
| `cache` | Inspect, verify, clean, or prune caches |

Advanced commands:

| Command | Purpose |
| --- | --- |
| `init` | Initialize folder structure |
| `rocm info` | Show ROCm/PyTorch and GPU info for an instance |
| `rocm validate` | Run ROCm/PyTorch validation for an instance |
| `comfyui info` | Show ComfyUI and custom node info |
| `comfyui requirements` | Reinstall ComfyUI requirements |
| `comfyui nodes` | List, install, update, or add custom nodes |
| `comfyui update` | Update the ComfyUI source checkout and optionally reapply patches |
| `config` | Show or create `rocmroll.ini` |
| `profile` | Manage execution profiles |
| `patch` | List, apply, or remove ComfyUI source patches |
| `workspace` | Manage named path workspaces |
| `logs` | Show recent log files |
| `help` | Show command help |

Global options accepted by every command:

| Option | Meaning |
| --- | --- |
| `--quiet` | Suppress non-error output |
| `--verbose` / `--debug` | Show more native command output |
| `--json` | Emit structured JSON where supported |
| `--no-color` | Disable colored console output |
| `--log-level LEVEL` | Set the logging threshold |
| `--log-file PATH` | Write a log file |
| `--help` | Show help |

Common command-specific options:

| Option | Used by |
| --- | --- |
| `--workspace NAME` | Commands whose help explicitly lists workspace selection |
| `--channel stable\|preview\|nightly\|rdna1\|rdna2` | Instance install and list filtering |
| `--python VERSION` | Instance install; default `3.12.10` |
| `--name NAME` | Instance aggregate commands and workspace, environment, or profile commands |
| `--instance NAME` | Doctor, ROCm, ComfyUI, `profile apply`, and patch commands |
| `--environment`, `--rocm`, `--comfyui`, `--patches`, `--all` | Component scopes listed by instance info/update/repair/remove help |
| `--profile NAME` | Instance install and launch |
| `--force` | Forced install/update/removal or stale install-lock override where listed |
| `--gfx ARCH`, `--port PORT`, `--url HOST`, `--patch-id ID`, `--shared-workflows` | Specialized commands shown in command help |

## Examples

```powershell
# Create instances
.\rocmroll.bat instance install --name rocm-stable
.\rocmroll.bat instance install --name rocm-preview --channel preview
.\rocmroll.bat instance install --name rocm-nightly --channel nightly

# Launch
.\rocmroll.bat instance launch --name rocm-stable
.\rocmroll.bat instance launch --name rocm-stable --port 8189
.\rocmroll.bat instance launch --name rocm-stable --profile performance-autotune

# Update and repair
.\rocmroll.bat instance update --name rocm-stable
.\rocmroll.bat instance update --name rocm-stable --comfyui
.\rocmroll.bat instance update --name rocm-stable --force
.\rocmroll.bat instance repair --name rocm-stable --patches

# Diagnostics
.\rocmroll.bat doctor --system
.\rocmroll.bat doctor --gpu
.\rocmroll.bat doctor --instance rocm-stable
.\rocmroll.bat doctor --instance rocm-stable --json

# Custom nodes
.\rocmroll.bat comfyui nodes --instance rocm-stable
.\rocmroll.bat comfyui nodes --instance rocm-stable --update
.\rocmroll.bat comfyui nodes --instance rocm-stable --add https://github.com/user/ComfyUI-Node.git

# Remove
.\rocmroll.bat instance remove --name rocm-stable --patches
.\rocmroll.bat instance remove --name rocm-stable --environment
.\rocmroll.bat instance remove --name rocm-stable --all
.\rocmroll.bat instance remove --name rocm-stable --all --force
```

With no component flags, `instance info`, `instance update`, and `instance repair` default to all supported scopes. `instance remove` always requires an explicit scope. Partial removal preserves the instance state as `incomplete` so it can be repaired; successful repair clears the restored component markers and returns the instance to `ready` when none remain. Removing patches restores their backed-up source files before deleting patch metadata. `instance remove --all` removes the checkout, environment, launchers, instance/environment state, patch artifacts, and ComfyUI Desktop registration while preserving shared assets.

## Runtime And ROCm

The default runtime is Python `3.12.10`, controlled by `RuntimeVersion` and `source\manifests\python-runtimes.json`.

ROCmRoll downloads embeddable Python, enriches it with `include`, `libs`, and `Lib` from the full Python ZIP, bootstraps pip, upgrades `pip`, `setuptools`, and `wheel`, and writes runtime state.

Per-instance environments are copied from the runtime and named like:

```text
<instance>-py312
```

ROCm/PyTorch installation is selected by channel. Index-based installs can use wheels from `.cache\wheelhouse\<rocmIndex>\` through `--find-links` when that folder contains wheels.

Manual ROCm validation:

```powershell
.\rocmroll.bat rocm validate --instance rocm-stable
```

## Custom Nodes, Packages, And Patches

Default custom nodes are defined in `source\manifests\custom-nodes.json` and installed instance-locally:

```text
instances\<instance>\custom_nodes\
```

Current default nodes:

- `ComfyUI-Manager`
- `CFZ-SwitchMenu`
- `CFZ-Caching`
- `ComfyUI-HFRemoteVae`
- `ComfyUI-INT8-Fast-ROCM`

The full install applies the `rocm-performance` profile from `source\manifests\package-profiles.json`.

Current performance packages:

- `triton-windows==3.7.1.post27`
- `sageattention==1.0.6`
- `bitsandbytes` from a release wheel URL
- `flash-attn` from a release wheel URL
- `amd-aiter` from a release wheel URL

Package patches live in `source\patches\sageattention\`.

ComfyUI source patches live in `source\patches\comfyui\` and are managed with:

```powershell
.\rocmroll.bat patch list
.\rocmroll.bat patch list --instance rocm-stable
.\rocmroll.bat patch apply --instance rocm-stable
.\rocmroll.bat patch apply --instance rocm-stable --patch-id 001-avoid-comfyui-crashes-dynamic-vram
.\rocmroll.bat patch remove --instance rocm-stable --patch-id 001-avoid-comfyui-crashes-dynamic-vram
```

## Launch Behavior

Generated launchers are written to:

```text
launchers\<instance>.ps1
launchers\<instance>.bat
```

The launcher:

- Uses the instance Python environment
- Sets ROCm/HIP/PyTorch/Triton variables process-locally
- Prepends environment and ROCm SDK paths to process `PATH`
- Runs `rocm-sdk.exe init` when present
- Uses shared `input`, `output`, and `temp` folders
- Uses the instance `extra_model_paths.yaml`
- Starts ComfyUI on `127.0.0.1:8188` unless another port is provided
- Writes launch output to `logs\launch`

`--user-directory` is intentionally omitted because of a known ComfyUI database initialization issue. Use `--shared-workflows` to link workflows across instances:

```powershell
.\rocmroll.bat instance install --name rocm-stable
.\rocmroll.bat instance repair --name rocm-stable
```

Creating symbolic links on Windows requires Developer Mode or an elevated PowerShell session.

## State, Logs, Locks, And Cache

State files are JSON:

```text
.state\runtimes\runtime-<version>.json
.state\environments\environment-<name>.json
.state\instances\instance-<name>.json
.state\global.json
.state\patches\
```

Install logs are written as both human-readable logs and JSONL:

```text
logs\install\<yyyy-mm-dd>_<instance>_install.log
logs\install\<yyyy-mm-dd>_<instance>_install.jsonl
```

Show recent logs:

```powershell
.\rocmroll.bat logs show
```

The full install/update pipeline uses an instance lock under `.state\locks\`. `--force` can override a stale install lock and requests forced recreation during full install/update.

Cache commands:

```powershell
.\rocmroll.bat cache list
.\rocmroll.bat cache verify
.\rocmroll.bat cache clean --temp
.\rocmroll.bat cache clean --all
.\rocmroll.bat cache prune --older-than-days 30
```

`cache clean --temp` clears the temp folder and partial downloads. `cache clean --all` clears downloads, wheelhouse, Git cache, Triton cache, and temp. Running `cache clean` without flags removes partial downloads only.

## ComfyUI Desktop Integration

If ComfyUI Desktop is installed and `%APPDATA%\Comfy Desktop\installations.json` exists, ROCmRoll registers or updates the installed instance there.

The Desktop integration:

- Does nothing when ComfyUI Desktop is absent
- Writes atomically
- Reuses an existing Desktop ID on update
- Removes the Desktop entry during full removal and when ComfyUI or environment components are removed
- Stores the Desktop ID in instance state as `comfyDesktopId`

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for known issues and solutions.

Start with diagnostics:

```powershell
.\rocmroll.bat doctor --instance rocm-stable
.\rocmroll.bat doctor --system
.\rocmroll.bat doctor --gpu
```

Known ComfyUI database issue:

```text
[ERROR] Failed to initialize database...
(sqlite3.OperationalError) unable to open database file
```

ROCmRoll works around this by omitting `--user-directory` from generated launchers. ComfyUI user data is written to the instance-local `instances\<instance>\user\` folder. Use `--shared-workflows` when workflows should be shared.

## Development Notes

Keep business logic in `source\modules\*.psm1`; keep batch files as thin wrappers. Major behavior changes should update the relevant module, manifest, template, README section, and [docs/architecture.md](docs/architecture.md).

Useful local checks:

```powershell
.\rocmroll.bat help
.\rocmroll.bat doctor --system
.\rocmroll.bat doctor --gpu
.\rocmroll.bat doctor --instance rocm-stable --json
```

PowerShell parse check example:

```powershell
$errors = $null
[System.Management.Automation.PSParser]::Tokenize((Get-Content .\source\rocmroll.ps1 -Raw), [ref]$errors) | Out-Null
$errors
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

## Credits

ROCmRoll builds on the work of these projects and people:

- [ComfyUI](https://github.com/comfyanonymous/ComfyUI)
- [AMD TheRock Team](https://github.com/ROCm/TheRock)
- [patientx-cfz](https://github.com/patientx-cfz/comfyui-rocm)
- [0xDELUXA](https://github.com/0xDELUXA)
- [kijai](https://github.com/kijai)
- [Apophis3158](https://github.com/Apophis3158)

## License

MIT - see [LICENSE](LICENSE).

## About

[![Made in Brazil](https://selo.feitonobrasil.dev.br/en/colorido/1x.svg)](https://feitonobrasil.dev.br)

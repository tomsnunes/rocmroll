# ComfyUI ROCmRoll

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078d7.svg)](https://www.microsoft.com/windows)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](https://github.com/PowerShell/PowerShell)
[![AMD ROCm](https://img.shields.io/badge/AMD-ROCm-ED1C24.svg)](https://rocm.docs.amd.com)

ComfyUI ROCmRoll is a Windows platform manager for building, launching, updating, diagnosing, and repairing portable ComfyUI installations optimized for AMD GPUs with ROCm packages.

The project is designed around a clean split:

- ROCmRoll owns orchestration: downloads, caches, Python runtimes, Python environments, ROCm/PyTorch packages, manifests, state, logs, launchers, diagnostics, and repair flows.
- ComfyUI instances own only their ComfyUI checkout, instance-local `custom_nodes`, generated ComfyUI configuration, and instance metadata.

That separation makes ComfyUI instances disposable and reproducible while keeping heavy assets such as models, input, output, and caches shared outside the ComfyUI source tree.

## Status

This repository contains both the accepted design/specification documents and the active PowerShell implementation.

Implemented pieces include:

- Thin `rocmroll.bat` wrapper around `source\rocmroll.ps1`
- Full install orchestration through PowerShell modules
- Python 3.12.10 runtime creation from embeddable Python plus full ZIP enrichment
- Per-instance Python environments copied from the runtime
- AMD GPU detection with JSON output and manual `--gfx` override
- Stable, nightly, and preview ROCm/PyTorch channel manifests
- ComfyUI Git mirror cache and per-instance clone
- Instance-local custom node install/update
- Generated `extra_model_paths.yaml`
- Generated launchers under `launchers\`
- Shared model and data folders
- ROCm/PyTorch validation via inline Python check in the instance environment
- `doctor`, `repair`, `list`, `remove`, `cache`, and `logs` commands
- JSON state files, human logs, JSONL logs, and PID lock files
- Optional ComfyUI Desktop registration when Desktop is installed
- User configuration file (`rocmroll.ini`) for portable path customization
- Execution profiles for environment variables and ComfyUI launch arguments

## Requirements

ROCmRoll targets:

- Windows only
- PowerShell 5.1 or newer
- Git available in `PATH`
- An AMD Radeon GPU mapped in `source\manifests\rocm-architectures.json`, or a manual `--gfx` override
- AMD graphics driver installed
- Long path support enabled in Windows is strongly recommended
- An ASCII-only install path is recommended, for example `C:\Platform\ai`
- Network access to Python, PyPI, GitHub, AMD ROCm package endpoints, and ROCm nightly indexes
- Enough disk space for Python runtimes, ComfyUI checkouts, ROCm/PyTorch wheels, caches, models, and outputs

Unsupported by design:

- Linux, WSL, and macOS
- NVIDIA and Intel GPU backends
- Global custom node sharing across all instances
- Silent modification of ComfyUI core source files

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
.\rocmroll.bat install --instance rocm-stable --channel stable
```

Launch it:

```powershell
.\rocmroll.bat launch --instance rocm-stable
```

By default, the generated launcher starts ComfyUI on:

```text
http://127.0.0.1:8188
```

Use a different port at launch time:

```powershell
.\rocmroll.bat launch --instance rocm-stable --port 8189
```

If more than one ready instance exists, `launch` can be run without `--instance` and ROCmRoll will show an interactive selector:

```powershell
.\rocmroll.bat launch
```

## Channels

Channels are defined in `source\manifests\channels.json`.

### Stable

The `stable` channel is the default and is intended to be a pinned known-good ROCmRoll profile.

Current stable profile:

- Python: `3.12.10`
- ComfyUI repo: `https://github.com/Comfy-Org/ComfyUI.git`
- ComfyUI ref: `v0.24.0`
- ROCm source: AMD direct URLs
- ROCm version: `7.2.1`
- torch: `2.9.1+rocm7.2.1`
- torchvision: `0.24.1+rocm7.2.1`
- torchaudio: `2.9.1+rocm7.2.1`
- Python wheel tag: `cp312`

Because the stable ROCm wheels are tagged `cp312`, stable currently requires Python 3.12.

### Nightly

The `nightly` channel tracks newer, more volatile packages.

Current nightly profile:

- Python: `3.12.10`
- ComfyUI ref: `master`
- ROCm source: index URL
- Index base: `https://rocm.nightlies.amd.com/v2-staging`
- Index pattern: `https://rocm.nightlies.amd.com/v2-staging/<rocmIndex>/`
- Packages: `torch`, `torchvision`, `torchaudio`, and `rocm[libraries,devel]`
- Pre-release packages: enabled by the channel profile

Nightly is expected to break sometimes because it follows upstream package movement.

### Preview

The `preview` channel uses the `v2` (non-staging) AMD nightly index instead of `v2-staging`.

Current preview profile:

- Python: `3.12.10`
- ComfyUI ref: `master`
- ROCm source: index URL
- Index base: `https://rocm.nightlies.amd.com/v2`
- Index pattern: `https://rocm.nightlies.amd.com/v2/<rocmIndex>/`
- Packages: `torch`, `torchvision`, `torchaudio`, and `rocm[libraries,devel]`
- Pre-release packages: enabled

`v2` receives builds that have passed AMD's staging gate, making `preview` slightly more stable than `nightly` while still tracking pre-release packages.

```powershell
.\rocmroll.bat install --instance rocm-preview --channel preview
```

### RDNA1 and RDNA2

> **Warning — RDNA 1 (`gfx101X`) and RDNA 2 (`gfx103X`) are experimental and very unstable.**
> AMD has no official Windows ROCm support for these GPU families. Their ROCm and PyTorch wheels
> exist only on AMD's nightly staging indexes, are subject to removal or silent breakage without
> notice, and are not covered by AMD's Windows ROCm support policy. Expect frequent install
> failures, torch import errors, and generation quality regressions whenever upstream nightly
> packages change. Use these channels only if you have one of these GPUs and accept the
> instability trade-off.

RDNA 1 (`gfx101X`, RX 5000 series) and RDNA 2 (`gfx103X`, RX 6000 series) are not supported on AMD's official Windows stable release index. Their ROCm/PyTorch wheels are sourced from AMD's nightly indexes, so a dedicated channel is used for each family.

`rdna1` and `rdna2` are independent channels — not variants of stable. They pin ComfyUI at `v0.24.0`.

The `--pre` flag is applied selectively per channel, following the patientx-cfz reference install:

| Channel | ROCm packages | PyTorch packages |
| --- | --- | --- |
| `rdna1` | no `--pre` | no `--pre` |
| `rdna2` | no `--pre` | `--pre` (required for RDNA 2 torch wheels) |

When `--channel stable` is selected and ROCmRoll detects an RDNA 1 or RDNA 2 GPU, it automatically routes to the correct channel and logs the switch:

| GPU family | Auto-selected channel |
| --- | --- |
| `gfx101X` (RDNA 1) | `rdna1` |
| `gfx103X` (RDNA 2) | `rdna2` |

You can also select these channels explicitly:

```powershell
.\rocmroll.bat install --instance my-rdna1 --channel rdna1
.\rocmroll.bat install --instance my-rdna2 --channel rdna2
```

## Profiles

Execution profiles are named JSON presets that control environment variables and ComfyUI launch arguments. The active profile is loaded at launcher startup, so you can switch between configurations without reinstalling or editing generated files.

Profiles live in `profiles\` at the root folder. The directory is configurable via `rocmroll.ini`.

### Built-in Profiles

| Profile | Default channel | Summary |
| --- | --- | --- |
| `stable` | `stable` | AMD baseline. Minimal env vars, no acceleration flags. Mirrors the official `run_amd_gpu.bat`. |
| `stable-dynamic-vram` | — | Stable + `--enable-dynamic-vram`. For GPUs with limited VRAM. |
| `optimized` | `nightly`, `preview` | Full ROCm performance: Flash-Attention Triton, MIOpen, SageAttention, dynamic VRAM. |
| `performance-autotune` | — | Like optimized but enables aggressive MIOpen and Triton kernel autotuning. First run is slow; subsequent runs use cached kernels. |
| `experimental` | — | Placeholder for custom patches and unverified wheels. Not applied by default. |

When no `--profile` is specified, the launcher uses the default profile for the install channel (`stable` → `stable`, `nightly` → `optimized`, `preview` → `optimized`).

### Profile Commands

List all profiles:

```powershell
.\rocmroll.bat profile list
```

Show a profile's settings:

```powershell
.\rocmroll.bat profile show --profile optimized
```

Create a new profile interactively:

```powershell
.\rocmroll.bat profile create --profile my-profile
```

Remove a profile:

```powershell
.\rocmroll.bat profile remove --profile my-profile
```

### Using Profiles

Specify a profile at install time (baked into the generated launcher as the default):

```powershell
.\rocmroll.bat install --instance rocm-stable --profile stable-dynamic-vram
```

Override the profile at launch time without regenerating the launcher:

```powershell
.\rocmroll.bat launch --instance rocm-stable --profile performance-autotune
```

Or call the launcher script directly with the override:

```powershell
.\launchers\rocm-stable.ps1 -ProfileArg performance-autotune
```

Regenerate the launcher with a different default profile:

```powershell
.\rocmroll.bat repair --instance rocm-stable --component launchers --profile optimized
```

### Profile File Format

A profile is a JSON file at `profiles\<name>.json`:

```json
{
  "name": "my-profile",
  "description": "Description shown in profile list",
  "version": "1.0",
  "defaultForChannels": [],
  "env": {
    "COMFYUI_ENABLE_MIOPEN": "0",
    "FLASH_ATTENTION_TRITON_AMD_ENABLE": "TRUE"
  },
  "launchArgs": [
    "--disable-smart-memory",
    "--use-sage-attention",
    "--enable-dynamic-vram"
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

`env` is applied after the fixed ROCm infrastructure block, so profile values override the defaults. `launchArgs` is appended to the fixed path and port arguments. `legacyGpuOverrides` is applied only when the instance GPU family is `gfx101X` or `gfx103X`.

### Profile Flag Reference

Any ComfyUI startup flag can be placed in `launchArgs` and any environment variable in `env`. The tables below list every flag the interactive wizard exposes.

#### VRAM & Memory

| `launchArgs` entry | Description |
| --- | --- |
| `--gpu-only` | Store and run everything on the GPU |
| `--highvram` | Keep models loaded in GPU memory instead of unloading |
| `--lowvram` | Run text encoders on CPU to save VRAM |
| `--novram` | Minimal VRAM usage when `--lowvram` is not enough |
| `--cpu` | Use the CPU for everything (very slow) |
| `--reserve-vram N` | Reserve N GB of VRAM for the OS |
| `--enable-dynamic-vram` | Enable dynamic VRAM management (default: auto) |
| `--disable-dynamic-vram` | Force estimate-based model loading |
| `--disable-smart-memory` | Aggressively offload to RAM |
| `--disable-pinned-memory` | Disable pinned memory |
| `--fast-disk` | Prefer disk-backed dynamic loading over unpinned RAM |
| `--disable-async-offload` | Disable async weight offloading |
| `--mmap-torch-files` | Use mmap when loading `.ckpt` / `.pt` files |
| `--disable-mmap` | Disable mmap for safetensors files |

#### Attention

| `launchArgs` entry | Description |
| --- | --- |
| `--use-sage-attention` | SageAttention — best for AMD ROCm |
| `--use-flash-attention` | FlashAttention |
| `--use-split-cross-attention` | Split cross-attention optimization |
| `--use-quad-cross-attention` | Sub-quadratic cross-attention (recommended for RDNA 1/2 legacy GPUs) |
| `--use-pytorch-cross-attention` | PyTorch 2.0 built-in cross-attention |
| `--disable-xformers` | Disable xformers library |
| `--force-upcast-attention` | Force attention upcasting |

#### Precision

| `launchArgs` entry | Description |
| --- | --- |
| `--force-fp16` | Force 16-bit floating point globally |
| `--force-fp32` | Force 32-bit floating point globally |
| `--fp16-unet` | Run the diffusion model in fp16 |
| `--fp32-unet` | Run the diffusion model in fp32 |
| `--bf16-unet` | Run the diffusion model in bfloat16 |
| `--fp8_e4m3fn-unet` | Store UNET weights in fp8 e4m3fn |
| `--fp8_e5m2-unet` | Store UNET weights in fp8 e5m2 |
| `--fp16-vae` | Run the VAE in fp16 (may cause black images) |
| `--fp32-vae` | Run the VAE in fp32 |
| `--bf16-vae` | Run the VAE in bfloat16 |
| `--cpu-vae` | Run the VAE on the CPU |
| `--fp16-text-enc` | 16-bit text encoder weights |
| `--fp32-text-enc` | 32-bit text encoder weights |
| `--bf16-text-enc` | Brain float 16 text encoder |

#### Cache

| `launchArgs` entry | Description |
| --- | --- |
| *(default)* | RAM-pressure-based caching |
| `--cache-classic` | Old aggressive caching style |
| `--cache-lru N` | LRU cache with a maximum of N node results |
| `--cache-none` | No caching — re-executes every node; lowest RAM/VRAM usage |

#### Preview Method

| `launchArgs` entry | Description |
| --- | --- |
| `--preview-method METHOD` | `auto`, `none`, `taesd`, or `latent2rgb` |
| `--preview-size N` | Maximum preview image size in pixels (default: 512) |

#### Fast Optimizations

| `launchArgs` entry | Description |
| --- | --- |
| `--fast fp16_accumulation` | Use fp16 for accumulation — experimental speed-up |
| `--fast fp8_matrix_mult` | Use fp8 for matrix multiplication |
| `--fast autotune` | Autotune kernel configurations |
| `--deterministic` | Use slower deterministic PyTorch algorithms |

Multiple fast options can be combined: `"--fast", "fp16_accumulation,autotune"`.

#### ROCm / AMD Environment Variables

| `env` key | Description |
| --- | --- |
| `FLASH_ATTENTION_TRITON_AMD_ENABLE` | Enable Flash-Attention Triton AMD backend (`TRUE`) |
| `FLASH_ATTENTION_TRITON_AMD_AUTOTUNE` | Autotune Flash-Attention Triton kernels (`TRUE`) |
| `COMFYUI_ENABLE_MIOPEN` | Enable MIOpen kernel search (`1` = on, `0` = off) |
| `MIOPEN_FIND_ENFORCE` | MIOpen find enforcement (`1`) |
| `MIOPEN_FIND_MODE` | MIOpen find mode (`1` = full search, `2` = normal) |
| `MIOPEN_SEARCH_CUTOFF` | Maximum kernels to benchmark (`1` = fast, `100` = thorough) |
| `TRITON_PRINT_AUTOTUNING` | Print Triton autotuning results (`1` = on) |
| `TRITON_CACHE_AUTOTUNING` | Cache Triton autotuning results (`1` = on) |
| `PYTORCH_TUNABLEOP_ENABLED` | Enable PyTorch TunableOp (`1` = on) |
| `PYTORCH_MIOPEN_SUGGEST_NHWC` | Prefer NHWC memory layout for MIOpen convolutions (`1` = on) |

#### ComfyUI Triton Backend

| `launchArgs` entry | Description |
| --- | --- |
| `--enable-triton-backend` | Enable ComfyUI's Triton backend for kernel operations |

#### Custom Nodes & API

| `launchArgs` entry | Description |
| --- | --- |
| `--disable-api-nodes` | Disable API nodes and prevent frontend internet access |
| `--disable-all-custom-nodes` | Skip loading all custom nodes |
| `--enable-manager-legacy-ui` | Use the legacy ComfyUI-Manager UI |

## Supported GPU Families

Currently supported GPU architectures span RDNA 1–4, RDNA 3.5 (Strix Point / Strix Halo / Krackan Point integrated GPUs), Radeon Pro VII (Vega/GCN5), and AMD Instinct MI300/MI325/MI350/MI355 series (CDNA).
GPU architecture mapping lives in `source\manifests\rocm-architectures.json` and is used by `RocmRoll.Hardware`.

| GFX family | ROCm index | Architecture | Example devices | Pre-release required | Status |
| --- | --- | --- | --- | --- | --- |
| `gfx120X` | `gfx120X-all` | RDNA 4 | RX 9060, RX 9070, RX 9070 XT | yes | Supported |
| `gfx1150` | `gfx1150` | RDNA 3.5 / Strix Point | Radeon 890M | yes | Supported |
| `gfx1151` | `gfx1151` | RDNA 3.5 / Strix Halo | Radeon 8060S, 8050S, 8040S, 880M | yes | Supported |
| `gfx1152` | `gfx1152` | RDNA 3.5 / Krackan Point | Radeon 860M, 840M, 820M | yes | Supported |
| `gfx1153` | `gfx1153` | RDNA 3.5 | — | yes | Supported |
| `gfx110X` | `gfx110X-all` | RDNA 3 | RX 7900, RX 7800, RX 7700, RX 7600, W7900, W7800, W7700, Radeon 780M, 760M, 740M | yes | Supported |
| `gfx103X` | `gfx103X-all` | RDNA 2 (dGPU) | RX 6950, RX 6900, RX 6800, RX 6700, RX 6600, RX 6500, W6800, V620 | yes | **Experimental** |
| `gfx101X` | `gfx101X-dgpu` | RDNA 1 | RX 5700, RX 5600, RX 5500, Radeon Pro V520 | yes | **Experimental** |
| `gfx90X` | `gfx90X-dcgpu` | Radeon Pro VII | Radeon Pro VII | no | Supported |
| `gfx94X` | `gfx94X-dcgpu` | MI300 / MI325 | MI300A, MI300X, MI325X | no | Supported |
| `gfx950` | `gfx950-dcgpu` | MI350 / MI355 | MI350X, MI355X | yes | Supported |

> **Warning — RDNA 1/2 (`gfx101X`, `gfx103X`) are experimental and very unstable.** AMD has no official Windows ROCm support for these families. Their wheels exist only on AMD's nightly staging index and can disappear or break without notice. When `--channel stable` is used with one of these GPUs, ROCmRoll automatically switches to the `rdna1` or `rdna2` channel. See [RDNA1 and RDNA2](#rdna1-and-rdna2) for details.

Manual override example:

```powershell
.\rocmroll.bat install --instance rocm-stable --gfx gfx120X
```

Use the family keys from the manifest for overrides. Exact ASIC IDs that are not in the manifest should be added to `rocm-architectures.json` before use.

## What Install Does

The full install command:

```powershell
.\rocmroll.bat install --instance rocm-stable --channel stable
```

performs the following high-level flow:

1. Initializes the ROCmRoll folder structure.
2. Prepares cache folders.
3. Creates or reuses the Python runtime.
4. Creates or reuses the per-instance Python environment.
5. Detects the AMD GPU and resolves the ROCm index.
6. Installs ROCm/PyTorch packages for the selected channel.
7. Clones or updates the ComfyUI instance from the Git mirror cache.
8. Installs ComfyUI `requirements.txt`.
9. Generates `extra_model_paths.yaml`.
10. Installs default custom nodes.
11. Installs the `rocm-performance` package profile.
12. Generates launchers.
13. Binds the instance path into the environment `python312._pth`.
14. Writes instance and environment state.
15. Registers the instance in ComfyUI Desktop if Desktop is present.
16. Runs validation.

Re-running the same command is intended to converge the instance to the requested state and reuse caches where possible.

## Project Layout

Source and documentation:

```text
rocmroll.bat                  Thin Windows wrapper
source\rocmroll.ps1              Main CLI entrypoint
source\modules\                  PowerShell modules
source\manifests\                Channel, runtime, GPU, package, patch, and node manifests
source\templates\                Generated launcher and ComfyUI config templates
docs\architecture.md          Full architecture and implementation specification
```

Generated runtime layout after `init` or `install`:

```text
rocmroll.ini                  Optional user configuration file (created by init)
.cache\                       Download, pip, Git, wheelhouse, checksum, and tool caches
.state\                       Runtime, environment, instance, patch, lock, and global state
.temp\                        Temporary extraction/work folder
shared\temp\                  Shared ComfyUI temp directory
shared\user\                  ComfyUI user data (see Shared Workflows)
environments\                 Per-instance Python environments
instances\                    Per-instance ComfyUI checkouts
launchers\                    Generated .ps1 and .bat launchers
logs\                         Install, launch, update, doctor, and crash logs
profiles\                     Execution profile JSON files
runtimes\                     Shared Python runtimes
shared\input\                 Shared ComfyUI input directory
shared\models\                Shared model storage
shared\output\                Shared ComfyUI output directory
shared\workflows\             Shared workflows (linked into instances via --shared-workflows)
```

Shared model subfolders are created for common ComfyUI model classes:

```text
checkpoints
clip
clip_vision
configs
controlnet
diffusion_models
embeddings
loras
upscale_models
vae
text_encoders
```

## Configuration

ROCmRoll reads an optional `rocmroll.ini` file from the root folder. When present it lets users redirect top-level directories to arbitrary locations without touching any code. All shared I/O paths (`input\`, `output\`, `temp\`, `user\`) are derived from the `shared` key — there is no longer a separate `data` folder.

Create the file with defaults commented out:

```powershell
.\rocmroll.bat config init
```

Show the currently resolved paths:

```powershell
.\rocmroll.bat config show
```

The file is plain INI. Paths can be absolute or relative to the file's directory:

```ini
; ROCmRoll Configuration
; Paths can be absolute (C:\MyData) or relative to this file's directory.
; Remove the leading semicolon from any line to override that value.

[paths]

; shared       = shared
; userdata     = shared\user
; instances    = instances
; environments = environments
; runtimes     = runtimes
; launchers    = launchers
; profiles     = profiles
; logs         = logs
; state        = .state
; cache        = .cache

; All shared asset sub-paths (input\, output\, temp\, user\, models\, workflows\)
; are derived from the shared key above. There is no separate data folder.
```

Example — move all instances and environments to a second drive while keeping cache local:

```ini
[paths]
instances    = D:\comfy\instances
environments = D:\comfy\environments
```

Example — move all shared assets (input, output, temp, models, workflows) to a second drive:

```ini
[paths]
shared = D:\comfy\shared
```

Example — move only instances and environments while keeping everything else local:

```ini
[paths]
instances    = D:\comfy\instances
environments = D:\comfy\environments
```

All sub-paths (pip cache, state files, log subfolders, etc.) continue to be derived from their parent. Source files (`source\`) are always resolved relative to `rocmroll.ps1` and are never configurable.

When no `rocmroll.ini` exists, all paths default to subdirectories of the root folder.

## Workspaces

A **workspace** is a named set of path overrides stored as a JSON file in `workspaces\`. Workspaces let you maintain separate root directories for different purposes (production vs. staging, C: drive vs. D: drive) and switch between them with a single command — no more manually commenting and uncommenting blocks in `rocmroll.ini`.

### Path resolution precedence

1. `--workspace NAME` on the command line — transient, highest (see below)
2. Active workspace paths (from `[active]` section in `rocmroll.ini`)
3. `[paths]` section in `rocmroll.ini`
4. Built-in defaults (lowest)

This means `[paths]` entries remain useful for base settings shared across all workspaces (e.g. `cache = D:\.cache` or `profiles = profiles`). A workspace only needs to declare the keys that differ.

### Using --workspace with any command

Append `--workspace NAME` to any command to use that workspace's paths for a single invocation without changing the persistent active workspace in `rocmroll.ini`.

```powershell
# Install into the staging paths without permanently switching workspaces
.\rocmroll.bat install --instance rocm-stable --workspace staging

# Run doctor against the production paths
.\rocmroll.bat doctor --instance rocm-stable --workspace production

# List instances in the staging workspace
.\rocmroll.bat list --workspace staging

# Launch using staging paths
.\rocmroll.bat launch --instance rocm-stable --workspace staging
```

When `--workspace NAME` is supplied the specified workspace file must exist in `workspaces\`. The transient override does not write to `rocmroll.ini`, so the previously-active workspace remains unchanged for the next command.

When no workspace is active and none has been created, all commands use the paths from `rocmroll.ini [paths]` (or built-in defaults) — this is the implicit **default** context, shown as `(default) [active]` in `rocmroll workspace list`.

### Quick start

```powershell
# Create a workspace for your D: drive setup (interactive wizard)
.\rocmroll.bat workspace create --workspace production

# Switch to it
.\rocmroll.bat workspace use --workspace production

# Verify resolved paths
.\rocmroll.bat config show

# Switch back
.\rocmroll.bat workspace use --workspace staging
```

### Migrating an existing rocmroll.ini

If you currently have multiple path blocks commented in and out of `rocmroll.ini`, you can migrate to workspaces in three steps:

```powershell
# 1. Save the currently active [paths] block as a named workspace
.\rocmroll.bat workspace init --workspace staging

# 2. Clear those paths from [paths] (or leave them as a fallback base)
#    Then create the second workspace with the wizard
.\rocmroll.bat workspace create --workspace production

# 3. Switch between them going forward
.\rocmroll.bat workspace use --workspace production
.\rocmroll.bat workspace use --workspace staging
```

### Workspace commands

| Command | Description |
| --- | --- |
| `workspace list` | List all workspaces; marks the active one |
| `workspace show --workspace NAME` | Print the paths stored in a workspace |
| `workspace create --workspace NAME` | Interactive wizard to create a workspace |
| `workspace use --workspace NAME` | Switch the active workspace |
| `workspace edit --workspace NAME` | Re-run the wizard on an existing workspace |
| `workspace remove --workspace NAME` | Delete a workspace (adds `--force` to skip prompt) |
| `workspace init --workspace NAME` | Save current resolved paths as a new workspace |

`workspace use` without `--workspace` shows an interactive selector when multiple workspaces exist.

### Workspace JSON format

Workspaces are stored in `workspaces\<name>.json`:

```json
{
  "name": "staging",
  "description": "D: drive staging environment",
  "createdAt": "2026-06-14T00:00:00.0000000-03:00",
  "paths": {
    "shared":       "D:\\platform\\ai\\comfyui\\shared",
    "instances":    "D:\\platform\\ai\\comfyui\\instances",
    "environments": "D:\\platform\\ai\\comfyui\\environments",
    "runtimes":     "D:\\platform\\ai\\comfyui\\runtimes",
    "launchers":    "D:\\platform\\ai\\comfyui\\launchers",
    "logs":         "D:\\platform\\ai\\comfyui\\logs",
    "state":        "D:\\platform\\ai\\.state",
    "cache":        "D:\\.cache"
  }
}
```

Only keys that differ from defaults need to be specified. Supported path keys mirror the `[paths]` section: `shared`, `userdata`, `instances`, `environments`, `runtimes`, `launchers`, `profiles`, `logs`, `state`, `cache`.

The `workspaces\` directory is always relative to the ROCmRoll root folder and is never redirectable. Source files and the `workspaces\` registry must remain at a fixed location so ROCmRoll can always find them.

## Command Reference

Get help:

```powershell
.\rocmroll.bat help
.\rocmroll.bat help install
.\rocmroll.bat install --help
.\rocmroll.bat help options
```

Common commands:

| Command | Purpose |
| --- | --- |
| `install` | Full install: runtime, environment, ROCm/PyTorch, ComfyUI, custom nodes, performance packages, launchers |
| `launch` | Launch a ready instance |
| `update` | Re-run full install for an existing instance with `--force` |
| `doctor` | Run diagnostics and health checks |
| `repair` | Repair a scoped component of an instance |
| `list` | List installed instances |
| `remove` | Remove an instance and its Python environment |
| `cache` | Inspect, verify, clean, or prune caches |
| `profile` | List, show, create, or remove execution profiles |

Advanced commands:

| Command | Purpose |
| --- | --- |
| `init` | Initialize the ROCmRoll folder structure |
| `rocm info` | Show installed ROCm/PyTorch packages and GPU info for an instance |
| `rocm validate` | Run the ROCm/PyTorch validation script for an instance |
| `comfy info` | Show ComfyUI version and custom node list for an instance |
| `comfy requirements` | Reinstall ComfyUI `requirements.txt` into an instance environment |
| `comfy nodes` | List installed custom nodes for an instance |
| `comfy update-nodes` | Pull latest commits for all custom nodes |
| `comfy add-node` | Install a custom node from a git repository URL |
| `comfy node-requirements` | Reinstall `requirements.txt` for all custom nodes |
| `logs` | Show recent log files |
| `config` | Show or create the `rocmroll.ini` configuration file |

Global options:

| Option | Meaning |
| --- | --- |
| `--instance NAME` | Target instance name |
| `--workspace NAME` | Transient workspace override — uses that workspace's paths for this command only, without changing the active workspace |
| `--channel stable\|nightly\|preview\|rdna1\|rdna2` | Update channel, default `stable`; `rdna1`/`rdna2` are experimental and very unstable (auto-selected for RDNA 1/2 GPUs when stable is requested) |
| `--python VERSION` | Python version, default `3.12.10` |
| `--port PORT` | ComfyUI launch port, default `8188` |
| `--gfx ARCH` | Override GPU architecture family |
| `--component SCOPE` | Repair scope |
| `--env NAME` | Explicit environment name for lower-level commands |
| `--url URL` | Git repository URL (`comfy add-node` only) |
| `--older-than-days N` | Cache prune age |
| `--profile NAME` | Execution profile name |
| `--rollback-patch ID` | Patch ID to roll back |
| `--force` | Force overwrite or stale lock override |
| `--shared-workflows` | Symlink instance workflows to `shared\workflows` |
| `--quiet` | Suppress non-error output |
| `--verbose` / `--debug` | Show more native command output |
| `--json` | Emit structured JSON where supported |
| `--no-color` | Disable colored console output |
| `--log-file PATH` | Write a log file |
| `--help` | Show command help |

## Examples

Create a stable instance:

```powershell
.\rocmroll.bat install --instance rocm-stable
```

Create a nightly instance:

```powershell
.\rocmroll.bat install --instance rocm-nightly --channel nightly
```

Update an instance:

```powershell
.\rocmroll.bat update --instance rocm-stable
```

Update custom nodes:

```powershell
.\rocmroll.bat comfy update-nodes --instance rocm-stable
```

Run full diagnostics:

```powershell
.\rocmroll.bat doctor --instance rocm-stable
```

Get machine-readable diagnostics:

```powershell
.\rocmroll.bat doctor --instance rocm-stable --json
```

Repair ROCm packages:

```powershell
.\rocmroll.bat repair --instance rocm-stable --component rocm
```

Repair generated launchers:

```powershell
.\rocmroll.bat repair --instance rocm-stable --component launchers
```

Remove an instance and its environment:

```powershell
.\rocmroll.bat remove --instance rocm-stable
```

Remove without confirmation:

```powershell
.\rocmroll.bat remove --instance rocm-stable --force
```

## Python Runtime and Environments

The default runtime is Python `3.12.10`, controlled by `RuntimeVersion` in `source\manifests\python-runtimes.json`.

If the requested version has an entry in the manifest, ROCmRoll uses the URLs declared there. If the version is not listed, ROCmRoll automatically constructs the download URLs from the standard python.org FTP layout and verifies both archives exist before proceeding. If either URL is unreachable the install fails with error `ROCMROLL-RUNTIME-005` and a message indicating the missing URL.

Runtime creation downloads (example for `3.12.10`):

- `python-3.12.10-embed-amd64.zip`
- `python-3.12.10-amd64.zip`
- `get-pip.py`

ROCmRoll extracts embeddable Python, enriches it with `include`, `libs`, and `Lib` from the full Python ZIP, generates the version-appropriate `pythonXYZ._pth` file, bootstraps pip, upgrades `pip`, `setuptools`, and `wheel`, validates the runtime, and writes runtime state.

Per-instance environments are copied from the runtime. The full install names them like:

```text
<instance>-py312
```

For example:

```text
rocm-stable-py312
```

ROCmRoll deliberately avoids using or modifying the user-level Python installation.

## ROCm and PyTorch

ROCm/PyTorch installation is selected by channel:

- `stable` installs AMD ROCm 7.2.1 direct URL wheels and tarball entries from the channel manifest.
- `nightly` installs from `https://rocm.nightlies.amd.com/v2-staging/<rocmIndex>/` (cutting-edge staging builds).
- `preview` installs from `https://rocm.nightlies.amd.com/v2/<rocmIndex>/` (promoted nightly builds; more stable than `nightly`).

For index-based installs, if `.cache\wheelhouse\<rocmIndex>\` contains wheels, ROCmRoll adds it as a `--find-links` source.

ROCm validation is performed by `Invoke-ValidateRocm` in `RocmRoll.Rocm`. It runs an inline Python script inside the instance environment (no separate script file) and checks:

- `torch` import
- torch version
- `torch.cuda.is_available()`
- HIP version
- device count
- device name
- a simple GPU tensor operation

Manual validation example:

```powershell
.\rocmroll.bat rocm validate --instance rocm-stable
```

## Custom Nodes

Custom nodes are instance-local by design:

```text
instances\<instance>\custom_nodes\
```

This avoids one experimental instance breaking another.

Default custom nodes are defined in `source\manifests\custom-nodes.json`:

- `ComfyUI-Manager`
- `CFZ-SwitchMenu`
- `CFZ-Caching`
- `ComfyUI-HFRemoteVae`
- `ComfyUI-INT8-Fast-ROCM`

ROCmRoll clones missing nodes, optionally updates existing nodes with `--update`, installs each node's `requirements.txt` when requested by the manifest, and logs failures as warnings where possible.

## Performance Package Profile

The full install currently applies the `rocm-performance` profile from `source\manifests\package-profiles.json`.

Current packages:

- `triton-windows==3.6.0.post25`
- `sageattention==1.0.6`
- `bitsandbytes` from a release wheel URL
- `flash-attn` from a release wheel URL
- `amd-aiter` from a release wheel URL

The `sageattention` package references the `sageattention-zluda-rdna` patch in `source\manifests\patches.json`. Patch downloads are cached under `.cache\downloads\patches`, originals are backed up under `.state\patches`, and rollback is exposed through:

```powershell
.\rocmroll.bat repair --instance rocm-stable --rollback-patch sageattention-zluda-rdna
```

Package availability for acceleration libraries can be volatile. The manifest is the place to adjust package versions, URLs, required flags, skip architectures, or local experiments.

## Launch Behavior

Generated launchers are written to:

```text
launchers\<instance>.ps1
launchers\<instance>.bat
```

`rocmroll launch` executes the generated PowerShell launcher.

The launcher:

- Uses the instance Python environment
- Sets ROCm/HIP/PyTorch/Triton variables process-locally
- Prepends the environment, `Scripts`, and ROCm SDK paths to process `PATH`
- Runs `rocm-sdk.exe init` when present
- Uses `shared\input`, `shared\output`, and `shared\temp`
- Uses `instances\<instance>\extra_model_paths.yaml`
- ComfyUI user data (including workflows) is written to `instances\<instance>\user\` (see [Shared Workflows](#shared-workflows))
- Starts ComfyUI on `127.0.0.1:8188` unless another port is provided
- Writes launch output to `logs\launch`

The launcher template always includes these fixed arguments:

```text
--listen 127.0.0.1
--port 8188
--extra-model-paths-config <instance>\extra_model_paths.yaml
--input-directory  <root>\shared\input
--output-directory <root>\shared\output
--temp-directory   <root>\shared\temp
```

`--user-directory` is intentionally omitted. See [Known ComfyUI Database Error](#known-comfyui-database-error).

The active profile's `launchArgs` are appended after the fixed arguments. For example, the `stable` profile adds:

```text
--disable-api-nodes
--preview-method auto
--enable-manager-legacy-ui
```

The `optimized` profile (`nightly` and `preview` channel default) additionally adds:

```text
--disable-smart-memory
--disable-pinned-memory
--use-sage-attention
--enable-dynamic-vram
```

Legacy GPU families `gfx101X` and `gfx103X` also receive `--use-quad-cross-attention` via the profile's `legacyGpuOverrides`.

Generated files should normally be changed through templates or repair commands rather than edited by hand.

## Shared Assets

ROCmRoll centralises all heavy assets under `shared\`:

| Directory | Purpose |
| --- | --- |
| `shared\input\` | ComfyUI input images and videos |
| `shared\output\` | Generated images and videos |
| `shared\temp\` | ComfyUI temporary processing files |
| `shared\user\` | ComfyUI user data (active once upstream `--user-directory` is re-enabled) |
| `shared\models\` | Model weights (checkpoints, LoRAs, VAEs, etc.) |
| `shared\workflows\` | Shared workflows (optional, via `--shared-workflows`) |

Each instance gets a generated:

```text
instances\<instance>\extra_model_paths.yaml
```

That file maps ComfyUI model categories to the shared model tree with forward-slash YAML paths.

Repair and remove operations are designed not to delete shared models, input, output, temp, or user data.

### Shared Workflows

Due to a [known ComfyUI bug](#known-comfyui-database-error), the `--user-directory` launch argument is currently disabled. ComfyUI therefore writes its user data (including workflows) to the instance-local path `instances\<instance>\user\default\`.

To share workflows across instances without requiring `--user-directory`, pass `--shared-workflows` at install or repair time:

```powershell
.\rocmroll.bat install --instance rocm-stable --shared-workflows
```

This creates a Windows symbolic link:

```text
instances\<instance>\user\default\workflows  ->  shared\workflows\
```

All instances installed with `--shared-workflows` read and write to the same `shared\workflows\` directory. Instances installed without the flag keep their own local workflows folder.

To add the link to an existing instance without reinstalling:

```powershell
.\rocmroll.bat repair --instance rocm-stable --component comfyui --shared-workflows
```

Creating symbolic links on Windows requires either Developer Mode enabled or an elevated (Administrator) PowerShell session.

## State, Logs, and Locks

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

Launch logs are written under:

```text
logs\launch\
```

Show recent logs:

```powershell
.\rocmroll.bat logs
```

Mutating instance work uses lock files under:

```text
.state\locks\
```

Locks include PID, timestamp, and host. Locks older than the configured stale threshold or owned by a dead process can be overridden with `--force`.

## Cache Management

ROCmRoll keeps reusable downloads and package caches under `.cache`.

Important cache folders:

```text
.cache\downloads\python
.cache\downloads\comfyui
.cache\downloads\rocm
.cache\downloads\tools
.cache\pip
.cache\wheelhouse
.cache\git
.cache\checksums
.cache\triton
```

Downloads use `.partial` files and are atomically renamed after success. Existing files are reused when they pass size/hash validation.

Cache commands:

```powershell
.\rocmroll.bat cache list
.\rocmroll.bat cache verify
.\rocmroll.bat cache clean --temp
.\rocmroll.bat cache clean --all
.\rocmroll.bat cache prune --older-than-days 30
```

`cache clean --temp` clears the temp folder and removes partial downloads. `cache clean --all` clears all caches (downloads, wheelhouse, git, triton, and temp). Running `cache clean` without flags removes partial downloads only. `cache prune` removes old files from the download cache by age.

## ComfyUI Desktop Integration

If ComfyUI Desktop is installed and `%APPDATA%\Comfy Desktop\installations.json` exists, ROCmRoll registers or updates the installed instance there.

The Desktop integration:

- Is a no-op when ComfyUI Desktop is absent
- Writes atomically to `installations.json`
- Reuses the existing Desktop ID on update when available
- Removes the Desktop entry during `rocmroll remove`
- Stores the Desktop ID in the instance state as `comfyDesktopId`

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for a full list of known issues and solutions.

Run diagnostics first:

```powershell
.\rocmroll.bat doctor --instance rocm-stable
```

For system-only checks:

```powershell
.\rocmroll.bat doctor --system
```

For GPU-only checks:

```powershell
.\rocmroll.bat doctor --gpu
```

### Known ComfyUI Database Error

ComfyUI raises a fatal error when launched with `--user-directory`:

```text
[ERROR] Failed to initialize database...
(sqlite3.OperationalError) unable to open database file
```

As a workaround, ROCmRoll omits `--user-directory` from generated launchers. ComfyUI writes user data (including workflows) to `instances\<instance>\user\` instead.

To share workflows between instances, use `--shared-workflows` at install time. See [Shared Workflows](#shared-workflows) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for details.

## Development Notes

The implementation is module-based. Keep business logic in `source\modules\*.psm1`; keep batch files as thin wrappers.

The most important modules are:

| Module | Responsibility |
| --- | --- |
| `RocmRoll.Config` | Canonical paths and folder initialization |
| `RocmRoll.Logging` | Console, log file, and JSONL logging |
| `RocmRoll.State` | Runtime, environment, instance, and global JSON state |
| `RocmRoll.Locking` | File locks and stale lock handling |
| `RocmRoll.Download` | Cached downloads, resume, and validation |
| `RocmRoll.Cache` | Cache inspection, verification, cleanup, and pruning |
| `RocmRoll.Runtime` | Python runtime creation |
| `RocmRoll.Environment` | Per-instance Python environments |
| `RocmRoll.Hardware` | GPU detection wrapper |
| `RocmRoll.Rocm` | ROCm/PyTorch install and validation |
| `RocmRoll.ComfyUI` | Git mirror, instance clone, dependencies, model paths |
| `RocmRoll.CustomNodes` | Custom node install/update |
| `RocmRoll.Packages` | Performance package profiles and patches |
| `RocmRoll.Launcher` | Launcher generation and launch execution |
| `RocmRoll.Profiles` | Execution profile management |
| `RocmRoll.Validation` | Instance validation checks |
| `RocmRoll.Doctor` | System/GPU/instance/cache diagnostics |
| `RocmRoll.Repair` | Component-scoped repair |
| `RocmRoll.ComfyDesktop` | Optional ComfyUI Desktop registration |
| `RocmRoll.UI` | Banner, step output, and console formatting |
| `RocmRoll.Encoding` | UTF-8 NoBOM text file helpers |
| `RocmRoll.Core` | Full install orchestration |

Specs are under `docs\specs` and are marked accepted. Major behavior changes should be reflected in the relevant spec, manifest, or template as well as the implementation.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

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

GPU and ROCm checks:

```powershell
# Native PowerShell GPU detection (no Python required)
.\rocmroll.bat doctor --gpu

# ROCm/PyTorch validation for an installed instance
.\rocmroll.bat rocm validate --instance rocm-stable
```

## Design Principles

- Keep ROCmRoll control-plane files outside ComfyUI checkouts.
- Make installs idempotent.
- Prefer manifests over hardcoded package decisions.
- Keep custom nodes instance-local.
- Share heavy data such as models across instances.
- Keep process environment changes local to the ROCmRoll command or generated launcher.
- Treat nightly as volatile.
- Do not delete user data during repair.
- Make patches explicit, cached, backed up, and reversible.
- Log external command output with enough context to diagnose failures.

## Credits

ROCmRoll builds on the work of these projects and people:

- [ComfyUI](https://github.com/comfyanonymous/ComfyUI) — the modular Stable Diffusion GUI and inference engine that ROCmRoll installs and manages.
- [AMD TheRock Team](https://github.com/ROCm/TheRock) — for the ROCm platform and the nightly wheel infrastructure that makes AMD GPU acceleration on Windows possible.
- [patientx-cfz](https://github.com/patientx-cfz/comfyui-rocm) — for pioneering ComfyUI ROCm setup guides and tooling on Windows that helped shape this project.
- [0xDELUXA](https://github.com/0xDELUXA) — for early research and tooling around ROCm on Windows that informed this project.
- [kijai](https://github.com/kijai) — for custom node work and contributions to the ComfyUI ecosystem.
- [Apophis3158](https://github.com/Apophis3158) - for awesome patches and fixes for ROCm.

## License

MIT — see [LICENSE](LICENSE).

## About

[![Made in Brazil](https://selo.feitonobrasil.dev.br/en/colorido/1x.svg)](https://feitonobrasil.dev.br)

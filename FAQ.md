# Frequently Asked Questions

---

## General

### What is ComfyUI ROCmRoll?

ROCmRoll is a Windows-only platform manager that installs, launches, updates, and repairs portable [ComfyUI](https://github.com/comfyanonymous/ComfyUI) setups optimized for AMD GPUs using the ROCm/PyTorch stack.

It handles everything outside ComfyUI itself: Python runtimes, per-instance environments, ROCm/PyTorch packages, GPU detection, shared model storage, generated launchers, diagnostics, and repair workflows.

### Why does this exist? Can't I just install ComfyUI normally?

The standard ComfyUI install on Windows with AMD GPUs involves several manual steps: finding the right ROCm-enabled PyTorch wheels for your specific GPU architecture, setting up the correct environment variables, managing Python versions, and handling the incompatibilities between AMD driver generations.

ROCmRoll automates all of this, makes installs reproducible and repairable, and lets you run multiple independent ComfyUI versions side by side.

### Is this an official AMD or ComfyUI project?

No. ROCmRoll is an independent community project. It is not affiliated with AMD, Comfy Org, or any GPU vendor.

---

## Hardware Support

### Which AMD GPUs are supported?

| Architecture | GFX family | Example cards |
| --- | --- | --- |
| RDNA 4 | gfx120X | RX 9060, RX 9070, RX 9070 XT |
| RDNA 3.5 / Strix Halo | gfx1151 | Radeon 8060S, 8050S, 8040S, 880M |
| RDNA 3 | gfx110X | RX 7900, RX 7800, RX 7700, RX 7600, Radeon 780M |
| RDNA 2 | gfx103X | RX 6900, RX 6800, RX 6700, RX 6600, RX 6500 |
| RDNA 1 | gfx101X | RX 5700, RX 5600, RX 5500 |

If your card is not listed, check `source\manifests\rocm-architectures.json` — it may be under a supported GFX family. You can also use a manual override:

```powershell
.\rocmroll.bat install --instance my-instance --gfx gfx120X
```

### Can I use ROCmRoll with an NVIDIA or Intel GPU?

No. ROCmRoll is AMD-only by design. For NVIDIA, the standard ComfyUI CUDA install works well. For Intel Arc, there are separate community efforts using IPEX.

### My GPU is not in the manifest. What do I do?

Find the GFX family your GPU belongs to (check the AMD ROCm documentation or GPU specs), then add it to `source\manifests\rocm-architectures.json` under the matching family. If your card works, please submit a pull request so others benefit too.

---

## Installation

### How long does a first install take?

A cold install (empty cache) downloads roughly 3-5 GB depending on channel and GPU architecture. On a fast connection this takes 10-20 minutes. Subsequent installs reuse the cache and are much faster.

### Can I run ROCmRoll from a path with spaces or Unicode characters?

It is strongly recommended to use an ASCII-only short path, for example `C:\Platform\ai`. Paths with spaces, non-ASCII characters, or excessive depth can cause failures in pip, Git, or the ROCm SDK.

### Can I move the install after setup?

Paths are baked into generated launchers, state files, and `python312._pth`. Moving the root folder requires regenerating launchers and potentially rebuilding environments. The safest approach is to set up `rocmroll.ini` with absolute paths before the first install, pointing to your desired locations.

### Can I put models, input, and output on a separate drive?

Yes. In `rocmroll.ini`, set:

```ini
[paths]
shared = D:\comfy\shared
```

This moves `shared\input\`, `shared\output\`, `shared\models\`, and `shared\workflows\` to `D:\comfy\shared\`. All instances automatically use the new location.

---

## Channels and Updates

### What is the difference between stable and nightly?

| | Stable | Nightly |
| --- | --- | --- |
| ROCm version | Pinned (7.2.1) | Latest AMD nightly |
| PyTorch | Pinned | Latest nightly |
| ComfyUI | Pinned release | `master` branch |
| Reliability | High | Variable |
| Pre-release packages | No | Yes |

Use stable for day-to-day work. Use nightly if you want the latest features and are comfortable with occasional breakage.

### How do I update an instance?

```powershell
.\rocmroll.bat update --instance rocm-stable
```

This re-runs the full install with `--force`, pulling the latest packages defined by the channel manifest.

### How do I update only the custom nodes?

```powershell
.\rocmroll.bat install-nodes --instance rocm-stable --update
```

---

## Multiple Instances

### Can I run two instances at the same time?

Yes, but each needs a different port:

```powershell
.\rocmroll.bat launch --instance rocm-stable  --port 8188
.\rocmroll.bat launch --instance rocm-nightly --port 8189
```

### Do instances share models?

Yes. All instances point to `shared\models\` via a generated `extra_model_paths.yaml`. Models downloaded once are available to every instance.

### Do instances share custom nodes?

No. Custom nodes are instance-local by design. This prevents one experimental instance from breaking another with incompatible node dependencies.

### Can instances share workflows?

Workflows live in the instance-local `user\default\workflows\` folder by default. To share them, use `--shared-workflows` at install time. This creates a symbolic link pointing all participating instances at `shared\workflows\`.

---

## Profiles

### What is an execution profile?

A JSON file that sets environment variables and ComfyUI launch arguments at startup time. Switching profiles does not require reinstalling — just pass `--profile <name>` at launch.

### Which profile should I use?

| Situation | Recommended profile |
| --- | --- |
| Stable channel, first-time setup | `stable` |
| Limited VRAM (under 12 GB) | `stable-dynamic-vram` |
| Nightly channel, best performance | `optimized` |
| Maximum kernel performance (long first run) | `performance-autotune` |

### Can I create my own profile?

```powershell
.\rocmroll.bat profile create --profile my-profile
```

This launches an interactive wizard. The result is a JSON file in `profiles\`.

---

## Troubleshooting

### Where do I find install logs?

```powershell
.\rocmroll.bat logs
```

Logs are under `logs\install\` as both human-readable `.log` and structured `.jsonl` files.

### Something is broken. Where do I start?

```powershell
.\rocmroll.bat doctor --instance rocm-stable
```

The doctor command checks the full instance health and prints actionable repair suggestions.

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for detailed guidance on specific errors.

### How do I completely remove an instance?

```powershell
.\rocmroll.bat remove --instance rocm-stable
```

This removes the instance checkout and its Python environment. Shared models, input, output, and workflows are never deleted.

---

## Contributing

### How do I report a bug?

Open a GitHub issue using the bug report template. Include the output of `.\rocmroll.bat doctor --instance <name> --json` and the relevant install log.

### How do I add support for a new GPU?

Edit `source\manifests\rocm-architectures.json` and add the GPU name under the correct GFX family. Test it, then submit a pull request.

### How do I propose a new feature?

Open a GitHub Discussion. If there is community interest, a spec is written in `docs/specs/` before implementation begins. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full process.

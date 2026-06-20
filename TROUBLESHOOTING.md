# Troubleshooting

This guide covers known issues, their causes, and the fastest path to a working state.

When something goes wrong, always run diagnostics first:

```powershell
.\rocmroll.bat doctor --instance <name>
.\rocmroll.bat doctor --system
.\rocmroll.bat doctor --gpu
```

---

## Table of Contents

- [Git Not Found](#git-not-found)
- [GPU Not Detected](#gpu-not-detected)
- [ROCm Install Fails](#rocm-install-fails)
- [GPU Not Available on RDNA 2 and RDNA 1](#gpu-not-available-on-rdna-2-and-rdna-1)
- [GPU Not Visible When Install Path Contains Spaces](#gpu-not-visible-when-install-path-contains-spaces)
- [Torch Import Fails After Install](#torch-import-fails-after-install)
- [ComfyUI Fails to Start](#comfyui-fails-to-start)
- [Known ComfyUI Database Error](#known-comfyui-database-error)
- [Shared Workflows Symlink Fails](#shared-workflows-symlink-fails)
- [Performance Package Failures](#performance-package-failures)
- [Stale Lock File](#stale-lock-file)
- [Long Path Failures](#long-path-failures)
- [Cache Corruption](#cache-corruption)
- [Python Runtime Errors](#python-runtime-errors)
- [Custom Node Install Failures](#custom-node-install-failures)
- [Nightly Channel Breaks](#nightly-channel-breaks)

---

## Git Not Found

**Symptom:**

```text
ERROR: git is not available in PATH.
```

**Cause:** Git for Windows is not installed or not in `PATH`.

**Fix:**

1. Install [Git for Windows](https://git-scm.com/download/win).
2. Open a new terminal to pick up the updated `PATH`.
3. Verify: `git --version`

---

## GPU Not Detected

**Symptom:**

```text
ERROR ROCMROLL-GPU-001: No supported AMD GPU detected.
```

**Diagnosis:**

```powershell
.\rocmroll.bat doctor --gpu
python .\source\scripts\gpu_detect.py --json
```

**Cause:** The GPU name returned by Windows WMI does not match any entry in `source\manifests\rocm-architectures.json`, or AMD drivers are not installed.

**Fix — Manual GFX override:**

```powershell
.\rocmroll.bat instance install --name rocm-stable --gfx gfx120X
```

Use the GFX family key from the `rocm-architectures.json` manifest.

**Fix — Add your GPU to the manifest:**

Open `source\manifests\rocm-architectures.json` and add your GPU under the correct GFX family. Submit a PR if it should be included for others.

**Fix — Install AMD drivers:**

Download and install the latest AMD Radeon Software from [amd.com](https://www.amd.com/en/support).

---

## ROCm Install Fails

**Symptom:**

```text
ERROR ROCMROLL-ROCM-003: pip install failed for torch.
```

**Quick recovery sequence:**

```powershell
.\rocmroll.bat cache clean --all
.\rocmroll.bat instance repair --name rocm-stable
.\rocmroll.bat doctor --instance rocm-stable
```

**Stable channel specifics:**

- Stable uses Python 3.12 ROCm wheels (`cp312`). If you overrode Python to a different version, the wheels will be incompatible.
- If the AMD direct URLs are unreachable, check your network or try again later.

**Nightly channel specifics:**

- Nightly indexes can move or go offline. This is expected — nightly is volatile.
- Try switching to stable when diagnosing whether the issue is local or upstream.

```powershell
.\rocmroll.bat instance install --name rocm-stable --channel stable
```

**Common pip failures:**

| Symptom | Fix |
| --- | --- |
| `SSL certificate verify failed` | Check system clock, update Windows root certificates |
| `No matching distribution found` | Your GPU may require `--pre` for pre-release packages |
| `Connection timeout` | Network issue or AMD server down — retry later |
| Partial wheel download stuck | `.\rocmroll.bat cache clean --all` |

---

## GPU Not Available on RDNA 2 and RDNA 1

**Symptom:** Install completes (possibly with a warning that the GPU was not visible during validation), but `torch.cuda.is_available()` is `False` and ComfyUI runs on CPU. Affects RX 6000 series (RDNA 2, `gfx103X`) and RX 5000 series (RDNA 1, `gfx101X`).

**Cause:** AMD's official ROCm Windows release wheels (the stable channel's direct URLs) only support RDNA 3 and RDNA 4 GPUs. They install without error on RDNA 1/2 systems but never detect the GPU. Additionally, AMD's regular nightly index (`v2`) does not publish torch wheels for these families - they exist only on the staging nightly index (`v2-staging`).

**Fix (automatic):** ROCmRoll routes `gfx103X` and `gfx101X` to the staging nightly index on both channels via the `sourceOverride` key in `source\manifests\rocm-architectures.json`. If your instance was installed before this fix, re-run the install (it converges) or repair the ROCm component:

```powershell
.\rocmroll.bat instance repair --name rocm-stable
.\rocmroll.bat instance repair --name rocm-stable
.\rocmroll.bat rocm validate --instance rocm-stable
```

**Note:** Staging nightly wheels are pre-release builds and inherit nightly volatility, even on the stable channel. This is currently the only way to get GPU acceleration on RDNA 1/2 under Windows.

---

## GPU Not Visible When Install Path Contains Spaces

**Symptom:** During install or launch from a root folder whose path contains a space (for example `D:\T2IAI\ComfyUI ROCmRoll\`), output like this appears and `torch.cuda.is_available()` is `False`:

```text
ComfyUI: Unknown command line argument 'ROCmRoll\environments\...\_rocm_sdk_core\lib\llvm\bin\offload-arch.exe'.
Try: 'D:\T2IAI\ComfyUI --help'
```

**Cause:** An upstream bug in AMD's `rocm_sdk` package (TheRock). It detects the GPU target family by spawning `offload-arch.exe` with an unquoted path. Windows splits the unquoted command line at the first space, so a different executable runs (in the example above, the portable `D:\T2IAI\ComfyUI.exe`), GPU detection fails, and torch falls back to CPU.

**Workaround (automatic):** ROCmRoll sets the `ROCM_SDK_TARGET_FAMILY` environment variable to the GPU family it detected itself (for example `gfx103X-dgpu`), both during install-time validation and in generated launchers. `rocm_sdk` honours this variable and skips the broken `offload-arch.exe` detection entirely.

The variable is only set when the installed distribution actually ships that family (`rocm_sdk` raises `ValueError` otherwise). The stable channel's direct-URL wheels ship a single family named `custom`, so the variable is intentionally not set there - single-family distributions resolve correctly on their own.

**If you see this on an existing instance,** regenerate the launcher to pick up the workaround:

```powershell
.\rocmroll.bat instance repair --name rocm-stable
.\rocmroll.bat rocm validate --instance rocm-stable
```

**Alternative:** reinstall ROCmRoll into a path without spaces (recommended root: `C:\Platform\ai`).

---

## Torch Import Fails After Install

**Symptom:**

```text
ImportError: DLL load failed while importing torch._C
```

**Diagnosis:**

```powershell
.\environments\rocm-stable-py312\python.exe .\source\scripts\verify_rocm.py --json
```

**Causes and fixes:**

| Cause | Fix |
| --- | --- |
| AMD driver not installed or outdated | Install/update from [amd.com](https://www.amd.com/en/support) |
| Missing ROCm SDK DLLs | `.\rocmroll.bat instance repair --name rocm-stable` |
| `rocm-sdk.exe init` was not run | Repair launchers, then launch again |
| PATH does not include ROCm bin | Generated launcher handles PATH — launch via `rocmroll instance launch` |

---

## ComfyUI Fails to Start

**Symptom:** ComfyUI process exits immediately or shows a Python traceback.

**Check the launch log:**

```powershell
.\rocmroll.bat logs
```

**Common causes:**

| Error message | Fix |
| --- | --- |
| `ModuleNotFoundError: No module named 'comfy'` | Repair ComfyUI deps: `.\rocmroll.bat instance repair --name rocm-stable` |
| `address already in use` | Another instance is using port 8188. Use `--port 8189`. |
| `extra_model_paths.yaml not found` | `.\rocmroll.bat instance repair --name rocm-stable` |
| SageAttention import error | `.\rocmroll.bat instance repair --name rocm-stable` |

---

## Known ComfyUI Database Error

**Symptom:**

```text
[ERROR] Failed to initialize database...
(sqlite3.OperationalError) unable to open database file
```

**Cause:** This error is triggered by the `--user-directory` launch argument. It is a confirmed upstream ComfyUI bug tracked at [ComfyUI#10040](https://github.com/Comfy-Org/ComfyUI/issues/10040).

**Current workaround:** ROCmRoll omits `--user-directory` from all generated launchers. ComfyUI writes its user data (settings, workflows) to the instance-local path:

```text
instances\<instance>\user\
```

**If you see this error in an old launcher:**

Regenerate the launcher to pick up the fix:

```powershell
.\rocmroll.bat instance repair --name rocm-stable
```

**Sharing workflows across instances:**

Use the `--shared-workflows` flag to create a symbolic link from the instance's workflow folder to `shared\workflows\`:

```powershell
.\rocmroll.bat instance install --name rocm-stable
```

Or add it to an existing instance:

```powershell
.\rocmroll.bat instance repair --name rocm-stable
```

This workaround will be removed once the upstream bug is fixed and ROCmRoll re-enables `--user-directory`.

---

## Shared Workflows Symlink Fails

**Symptom:**

```text
ERROR: Creating a symbolic link requires elevation or Developer Mode.
```

**Cause:** Windows restricts symbolic link creation to administrators or accounts with Developer Mode enabled.

**Fix — Enable Developer Mode (recommended):**

1. Open **Settings** > **System** > **For developers**.
2. Toggle **Developer Mode** on.
3. Re-run the install or repair command.

**Fix — Run as Administrator:**

Open PowerShell as Administrator and run:

```powershell
.\rocmroll.bat instance repair --name rocm-stable
```

**Note:** If `instances\<instance>\user\default\workflows` already exists as a real directory (with workflows in it), ROCmRoll will warn and skip rather than delete your data. Back up those workflows to `shared\workflows\` manually before re-running.

---

## Performance Package Failures

**Symptom:** `flash-attn`, `sageattention`, `bitsandbytes`, or `amd-aiter` fail to install or import.

**Context:** These packages are optional. Their availability depends on architecture, upstream release status, and wheel compatibility. A failure here does not prevent ComfyUI from starting.

**Diagnosis:**

```powershell
.\rocmroll.bat doctor --instance rocm-stable
```

Look for `[WARN]` entries rather than `[FAIL]` — optional packages report warnings, not failures.

**Rollback a bad patch:**

```powershell
.\rocmroll.bat instance repair --name rocm-stable
```

**Re-apply performance packages:**

```powershell
.\rocmroll.bat instance repair --name rocm-stable
```

**Skip a package permanently:** Edit `source\manifests\package-profiles.json` and set `"required": false` and add your GFX family to `"skipArchitectures"`.

---

## Stale Lock File

**Symptom:**

```text
ERROR ROCMROLL-LOCK-001: Instance 'rocm-stable' is locked by PID 12345.
```

**Cause:** A previous install or repair was interrupted and the lock file was not cleaned up.

**Check if the process is still running:**

```powershell
Get-Process -Id 12345 -ErrorAction SilentlyContinue
```

If the process is gone, the lock is stale.

**Fix:**

```powershell
.\rocmroll.bat instance install --name rocm-stable --force
```

`--force` validates the lock (PID and age) before removing it. It will not remove a lock held by an active process.

---

## Long Path Failures

**Symptom:** Installation fails with path-too-long errors deep in Python site-packages or ROCm SDK directories.

**Fix:**

1. Enable Windows long path support (run as Administrator):

```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1
```

   Or use Group Policy: **Computer Configuration > Administrative Templates > System > Filesystem > Enable Win32 long paths**.

1. Keep the root path short. The recommended path is:

```text
C:\Platform\ai
```

   Avoid paths with spaces, Unicode characters, or many nested directory levels.

---

## Cache Corruption

**Symptom:** Downloads fail with checksum errors or pip installs fail with corrupt wheel errors.

**Fix — Clear partial downloads:**

```powershell
.\rocmroll.bat cache clean
```

**Fix — Clear all caches:**

```powershell
.\rocmroll.bat cache clean --all
```

**Fix — Clear temp and partial downloads:**

```powershell
.\rocmroll.bat cache clean --temp
```

**Fix — Remove old downloads:**

```powershell
.\rocmroll.bat cache prune --older-than-days 30
```

---

## Python Runtime Errors

**Symptom:**

```text
ERROR: Python runtime validation failed.
```

**Diagnosis:**

```powershell
.\rocmroll.bat doctor --system
```

**Rebuild the runtime:**

```powershell
.\rocmroll.bat create-runtime --force
```

This re-downloads (or reuses cached) Python archives and rebuilds the runtime from scratch.

**Verify manually:**

```powershell
.\runtimes\python-3.12.10\python.exe -c "import sys; import site; print(sys.version); print(site.getsitepackages())"
```

---

## Custom Node Install Failures

**Symptom:** A custom node fails to clone or its requirements fail to install.

**Behaviour:** ROCmRoll logs custom node failures as warnings, not fatal errors. The install continues and ComfyUI starts. The failed node will be absent from `custom_nodes\`.

**Re-install nodes:**

```powershell
.\rocmroll.bat comfyui nodes --instance rocm-stable --update
```

**Update all nodes:**

```powershell
.\rocmroll.bat comfyui nodes --instance rocm-stable --update
```

**Skip a problem node:** Edit `source\manifests\custom-nodes.json` and remove the entry, or mark it optional if your version of the manifest supports that field.

---

## Nightly Channel Breaks

**Symptom:** Nightly install fails on ROCm package resolution or torch import after install.

**Expected behaviour:** Nightly is volatile by design. AMD nightly indexes can change, move packages, or temporarily drop support for a GFX family.

**Diagnosis:**

```powershell
.\rocmroll.bat doctor --instance rocm-nightly
```

**Quick fix — switch to stable:**

```powershell
.\rocmroll.bat instance install --name rocm-stable --channel stable
```

**Wait and retry:** Nightly issues are often resolved within 24-48 hours as AMD publishes new packages.

**Report the issue:** If nightly has been broken for more than 48 hours, open an issue with the output of:

```powershell
.\rocmroll.bat doctor --instance rocm-nightly --json
```

---

## Still Stuck?

1. Run `.\rocmroll.bat doctor --instance <name> --json` and capture the output.
2. Check `logs\install\` for the most recent install log.
3. Open an issue at the project repository with the doctor JSON and install log attached.

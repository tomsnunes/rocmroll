# ComfyUI ROCmRoll Architecture

ComfyUI ROCmRoll is a Windows-only PowerShell platform manager for portable ComfyUI installations on AMD GPUs. It builds Python runtimes and per-instance environments, installs ROCm/PyTorch packages, creates ComfyUI instances, manages custom nodes, generates launchers, runs diagnostics, and keeps shared assets outside disposable ComfyUI checkouts.

The implementation is intentionally module based. The CLI entrypoint is `source\rocmroll.ps1`, and the top-level wrapper `rocmroll.bat` only forwards arguments to PowerShell.

## Design

ROCmRoll keeps a hard boundary between its control plane and each ComfyUI instance.

ROCmRoll owns:

- Configuration and workspace path resolution
- Runtime, environment, cache, state, log, and lock folders
- Channel, GPU, package, runtime, custom-node, and patch manifests
- ROCm/PyTorch package installation and validation
- ComfyUI clone/update orchestration
- Generated launchers and generated ComfyUI configuration
- Diagnostics, repair, cache cleanup, and Desktop registration

Each ComfyUI instance owns:

- Its ComfyUI checkout under the configured `instances` folder
- Its instance-local `custom_nodes`
- Generated `extra_model_paths.yaml`
- Instance-local ComfyUI user data unless shared workflows are linked

Shared models, input, output, temp data, and optional shared workflows live under `shared\` by default and are not deleted by repair or instance removal.

## Repository Layout

Source-controlled files are arranged as follows:

```text
rocmroll.bat
README.md
TROUBLESHOOTING.md
FAQ.md
CONTRIBUTING.md
docs\architecture.md
docs\declarative-instances.md
profiles\*.json
source\rocmroll.ps1
source\modules\*.psm1
source\manifests\*.json
source\patches\comfyui\*.json
source\patches\sageattention\*.json
source\scripts\validate-rocm.py
source\templates\*.tpl
workspaces\*.json
overlays\<name>\<name>.yaml    Optional declarative instance definitions
overlays\<name>\environment\   Optional requirements.txt overlay
overlays\<name>\instance\      Optional custom_nodes.json / extra_model_paths.yaml overlays
```

Generated folders are created by `init` or `install`:

```text
.cache\        downloads, pip cache, Git mirrors, wheelhouse, Triton cache
.state\        runtime, environment, instance, patch, lock, and global state
.temp\         extraction and temporary work area
environments\  per-instance Python environments
instances\     per-instance ComfyUI checkouts
launchers\     generated .ps1 and .bat launchers
logs\          install, launch, update, doctor, and crash logs
runtimes\      reusable Python runtimes
shared\        input, output, temp, user, models, and workflows
```

## Configuration And Workspaces

`RocmRoll.Config` builds the canonical config object used by all modules. It reads `rocmroll.ini` from the repository root when present and supports these `[paths]` keys:

| Key | Default | Purpose |
| --- | --- | --- |
| `shared` | `shared` | Root for shared input, output, temp, user, models, and workflows |
| `userdata` | `shared\user` | ComfyUI user data root |
| `instances` | `instances` | ComfyUI checkouts |
| `environments` | `environments` | Python environments |
| `runtimes` | `runtimes` | Python runtimes |
| `launchers` | `launchers` | Generated launchers |
| `profiles` | `profiles` | Execution profile JSON files |
| `logs` | `logs` | Human and JSONL logs |
| `state` | `.state` | JSON state, locks, and patch backups |
| `cache` | `.cache` | Downloads, pip cache, Git cache, wheelhouse, checksums |

Internal source paths remain rooted at `source\` and are not user-configurable. The workspace registry folder, `workspaces\`, is also root-relative so ROCmRoll can always find it.

Workspaces are named JSON files in `workspaces\` that hold path overrides. Path precedence is:

1. `--workspace NAME` on the current command
2. Active workspace from `[active]` in `rocmroll.ini`
3. `[paths]` in `rocmroll.ini`
4. Built-in defaults

For cross-workspace inventory, `Initialize-Config -IgnoreActiveWorkspace` resolves the base `[paths]` configuration without applying `[active]`. `instance list --all` lists that base configuration first and then initializes each named workspace exactly once; a transient `--workspace` selection and `--all` are mutually exclusive.

Workspace commands are implemented by `RocmRoll.Workspace` and dispatched by `source\rocmroll.ps1`:

```powershell
rocmroll workspace list
rocmroll workspace show --name NAME
rocmroll workspace create --name NAME
rocmroll workspace use --name NAME
rocmroll workspace edit --name NAME
rocmroll workspace remove --name NAME
rocmroll workspace init --name NAME
```

## CLI And Modules

`source\rocmroll.ps1` is a thin bootstrapper. It initializes UTF-8 console output, loads the CLI support module, builds a command context, initializes config and logging, and delegates dispatch to command modules.

The command path is registry-driven:

1. `RocmRoll.Cli` defines commands, subcommands, options, defaults, required values, help, and handler names in one registry.
2. The parser validates the invocation and creates a normalized context. Handlers do not repeat required-option validation.
3. `RocmRoll.Commands` dispatches the context and lazily imports only the domain modules needed by that command family. Imports are cached for the process and are not force-reloaded per handler.
4. Domain modules perform configuration, state, installation, repair, removal, and other platform operations.

| Module | Responsibility |
| --- | --- |
| `RocmRoll.Cli` | Command registry, context parsing, help rendering, option validation, bootstrap initialization, and top-level dispatch |
| `RocmRoll.Commands` | Thin command handlers, command-family dispatch, and cached domain-module loading |
| `RocmRoll.Config` | Config, path resolution, folder initialization |
| `RocmRoll.Logging` | Console, file, JSONL, and native-command logging |
| `RocmRoll.Encoding` | UTF-8 NoBOM text and JSON formatting helpers |
| `RocmRoll.Utilities` | Shared filesystem and native-process helpers |
| `RocmRoll.Instance` | Instance discovery plus complete and component-scoped cleanup lifecycle |
| `RocmRoll.State` | Runtime, environment, instance, and global JSON state |
| `RocmRoll.Locking` | PID lock files and stale lock handling |
| `RocmRoll.Download` | Cached downloads and integrity checks |
| `RocmRoll.Cache` | Cache summary, verification, cleanup, pruning |
| `RocmRoll.Runtime` | Python runtime download, enrichment, validation |
| `RocmRoll.Environment` | Per-instance environment creation and binding |
| `RocmRoll.Hardware` | AMD GPU detection and architecture mapping |
| `RocmRoll.Rocm` | ROCm/PyTorch install planning, install, validation |
| `RocmRoll.ComfyUI` | Git mirror, clone/update, requirements, model paths |
| `RocmRoll.ModelPaths` | Drift-safe `extra_model_paths.yaml` generation, status classification, and mode-aware apply |
| `RocmRoll.CustomNodes` | Instance-local custom node install/update |
| `RocmRoll.Packages` | Performance package profile install and package patches |
| `RocmRoll.ComfyPatch` | Managed text patches for ComfyUI source files |
| `RocmRoll.Launcher` | Launcher generation and launch execution |
| `RocmRoll.Profiles` | Execution profile management |
| `RocmRoll.Validation` | Instance validation checks |
| `RocmRoll.Doctor` | System, GPU, instance, and cache diagnostics |
| `RocmRoll.Repair` | Component-scoped repair flows |
| `RocmRoll.ComfyDesktop` | Optional ComfyUI Desktop registration |
| `RocmRoll.UI` | Banner, step output, and summary formatting |
| `RocmRoll.Core` | Full install orchestration |
| `RocmRoll.YamlLite` | Minimal, dependency-free YAML subset reader for instance definitions |
| `RocmRoll.InstanceDefinition` | ComfyUIInstance YAML schema parsing, validation, defaulting, and export (reverse-engineering a definition from an existing instance) |
| `RocmRoll.InstancePlan` | Plan/apply/destroy engine comparing declared, recorded, and actual state |

Implemented CLI commands:

```text
init
instance
plan
apply
destroy
import
workspace
doctor
env
rocm
comfyui
cache
state
logs
config
profile
patch
help
```

`plan`, `apply`, `destroy`, and `import` are top-level commands (siblings of `instance`, not subcommands of it) - see Declarative Instance Management below.

## Instance Overlays

ROCmRoll supports per-instance resource overlays in an `overlays\` folder at the repository root. The folder is root-relative and not user-configurable via `rocmroll.ini`, following the same convention as `workspaces\`. It is also where declarative instance YAML definitions live (see Declarative Instance Management below), and `RocmRoll.Config.Get-InstanceOverlayFolder`/`Get-InstanceOverlayEnvironmentFolder`/`Get-InstanceOverlayInstanceFolder` are the shared helpers every module uses to resolve into it, so the layout only needs to change in one place.

### Layout

```text
overlays\
  <instanceName>\
    <instanceName>.yaml        Optional declarative instance definition
    environment\
      requirements.txt         Extra pip packages installed after ComfyUI requirements
    instance\
      custom_nodes.json        Extra custom nodes installed after the default manifest
      extra_model_paths.yaml   Overlay source for the instance's extra_model_paths.yaml
```

`requirements.txt` sits under `environment\` because it affects the Python environment (pip installs); `custom_nodes.json` and `extra_model_paths.yaml` sit under `instance\` because they affect the ComfyUI instance itself - the same environment/instance ownership split described under Design above.

### Custom requirements

`Invoke-InstallComfyDeps` (in `RocmRoll.ComfyUI`) checks for `overlays\<instanceName>\environment\requirements.txt` after installing ComfyUI's own `requirements.txt` and `manager_requirements.txt`. If the file exists it is installed with `pip install --upgrade-strategy only-if-needed -r <file>` using the shared pip cache. A failed install raises `ROCMROLL-COMFY-005`.

Because the custom requirements block lives inside `Invoke-InstallComfyDeps` it is automatically executed by all call sites: full install, `comfyui requirements`, `instance update --comfyui`, and `instance repair --comfyui`.

### Custom nodes

`Invoke-InstallCustomNodes` (in `RocmRoll.CustomNodes`) checks for `overlays\<instanceName>\instance\custom_nodes.json` after processing the global manifest. The file uses the same JSON schema (`{ "default": [ { name, repo, ref, installRequirements } ] }`). Each entry is processed by the shared `Invoke-ProcessNodeEntry` helper that handles clone, update, and requirements installation. Clone failures are non-fatal warnings.

Because the custom nodes block lives inside `Invoke-InstallCustomNodes` it is automatically executed by all call sites: full install, `comfyui nodes --install`, `comfyui nodes --update`, and `instance repair --custom-nodes`.

### Custom extra_model_paths.yaml overlay and preserve-on-update

`RocmRoll.ModelPaths` owns `extra_model_paths.yaml` generation instead of `RocmRoll.ComfyUI` writing it unconditionally. `Get-ExtraModelPathsDesiredContent` resolves, in order: `overlays\<instanceName>\instance\extra_model_paths.yaml` if present, else `source\templates\extra_model_paths.yaml.tpl`, else a built-in default; `{SharedFolder}` is substituted in either case.

`Get-ExtraModelPathsStatus` classifies the on-disk file against the `managedFiles.'extra_model_paths.yaml'` record in instance state (`contentHash`, `sourceHash`, `source`, `sourcePath`, `lastAppliedAt`):

| Status | Meaning |
| --- | --- |
| `missing` | File does not exist |
| `managed` | File matches what ROCmRoll last wrote and the source hasn't changed since |
| `source-changed` | File still matches what ROCmRoll last wrote, but the overlay/template source changed since - safe to auto-refresh |
| `custom-unknown` | File exists but has no `managedFiles` record |
| `drifted` | File exists and its hash no longer matches the recorded `contentHash` (hand-edited, or the record is stale) |

`Invoke-ApplyExtraModelPaths -Mode Install|Repair|Update|Apply` is mode-aware: `Update` always preserves an existing file (`custom-unknown`/`drifted` files are never touched by `--force` either, matching the acceptance criterion that update never destroys user data); `Install` replaces only with `-Force`; `Repair` regenerates `managed`/`source-changed` files automatically and prompts (`Invoke-ConfirmExtraModelPathsOverwrite`) before replacing `custom-unknown`/`drifted` ones unless `-Force`; `Apply` mirrors `Repair` but is driven by the plan engine's own destructive-approval gate instead of prompting a second time. `Invoke-GenerateExtraModelPaths` (in `RocmRoll.ComfyUI`) remains as a thin `-Mode Install` compatibility wrapper.

## Declarative Instance Management

ROCmRoll has two operation modes: an imperative one (the `instance` command family - `install`/`update`/`remove`/`launch`/`repair`/`list`/`info`) and a declarative one (`import`/`plan`/`apply`/`destroy`, `RocmRoll.InstanceDefinition` + `RocmRoll.InstancePlan`). The declarative commands are top-level, siblings of `instance` rather than subcommands of it, and they reuse the imperative pipeline under the hood instead of reimplementing it - see Terraform's `plan`/`apply` for the model this follows.

`import` (`Get-InstanceDefinitionSnapshot` + `ConvertTo-InstanceDefinitionYaml` in `RocmRoll.InstanceDefinition`) reverse-engineers a YAML definition from an already-installed instance's recorded state and filesystem (overlay presence, symlinked shared workflows, environment GPU/runtime info) so existing instances don't need a hand-written definition to be planned/applied against; `spec.profile` is always written empty since it isn't persisted in instance state.

A ComfyUIInstance YAML definition (default `overlays\<name>\<name>.yaml`, or `--file PATH`) is parsed by `RocmRoll.YamlLite` - a minimal, dependency-free block-mapping-and-scalars parser written for PowerShell 5.1, which has no built-in YAML support and this project avoids external module dependencies. It intentionally does not support YAML lists, flow style, or anchors; the schema doesn't need them. `RocmRoll.InstanceDefinition.Read-InstanceDefinition` validates `apiVersion`/`kind`/`metadata.name`/`spec.channel`, applies schema defaults (`pythonVersion`, `modelPaths.preserveOnUpdate: true`, `modelPaths.repairPolicy: confirm`, etc.), and collects unrecognized fields as non-fatal warnings.

`Get-InstancePlan` compares three layers - the YAML definition (desired), ROCmRoll-recorded state (`.state\instances\instance-<name>.json`), and the actual filesystem/runtime (checkout `.git` marker, environment folder, recorded Python version, launcher file, `custom_nodes` contents) - and produces a classified action list (`NOOP`/`CREATE`/`UPDATE`/`REPAIR`/`REPLACE`/`DELETE`/`PRESERVE`/`WARNING`, each with a `destructive` flag; action ids include `modelPaths.extra_model_paths`, `comfyui.source`, `channel`, `pythonVersion`, `environment`, `launcher`, `customNodes.unmanaged`, `paths.shared`).

`Invoke-InstanceApply` is capable of performing every action a full `instance install`/`instance update` can:

- `extra_model_paths.yaml` (`modelPaths.extra_model_paths`) is always reconciled directly first, via `RocmRoll.ModelPaths` with the same preserve/overlay/destructive-approval semantics as imperative install/repair/update.
- Anything needing the install/update pipeline - `environment`, `channel`, `pythonVersion`, or `comfyui.source` being `CREATE`/`UPDATE` - triggers a single call to `RocmRoll.Core.Invoke-FullInstall` (`-IsUpdate` when the instance already exists), the exact same function `instance install`/`instance update` use. This is what makes apply reuse the imperative subset instead of duplicating it, and it converges the same way re-running install/update already does.
- A pending launcher-only `CREATE` (nothing else pending) is regenerated directly (`Invoke-GenerateLaunchers`) without paying for the full pipeline.
- Informational `WARNING` actions (unmanaged custom nodes, a declared `paths.shared` mismatch) are never auto-applied.

Destructive actions are blocked unless `--allow-destructive` or `spec.updatePolicy.allowDestructive: true` is set; non-destructive actions still prompt for confirmation unless `--auto-approve` or `spec.updatePolicy.requirePlan: false`. `apply` accepts `--file PATH` (compute and apply in one step) or `--plan PATH` (apply a plan previously saved by `plan --output`); `Test-InstancePlanStale` warns when a saved plan's actions no longer match what a fresh plan would produce.

`Get-InstanceDestroyPlan`/`Invoke-InstanceDestroy` are the teardown counterpart: `Get-InstanceDestroyPlan` builds a `DELETE`/`PRESERVE` action list (checkout, environment, launcher, patch state, and ComfyUI Desktop registration as `DELETE`; shared assets and the instance's `overlays\<name>\` folder as `PRESERVE`) in the same shape `Get-InstancePlan` produces, so `Format-InstancePlanText`/`ConvertTo-InstancePlanJson` render it unchanged. `Invoke-InstanceDestroy` then calls `RocmRoll.Instance.Remove-RocmRollInstance` - the same function `instance remove --all` uses - so `destroy` reuses that removal pipeline rather than reimplementing it, mirroring how `apply` reuses `Invoke-FullInstall`. Because destruction is irreversible, confirmation requires typing the instance's exact name rather than a plain `y`/`N`, unless `--auto-approve` is passed; `--dry-run` shows the plan without prompting or deleting anything.

See [declarative-instances.md](declarative-instances.md) for the full schema, CLI reference, and worked examples.

## Install Pipeline

`RocmRoll.Core.Invoke-FullInstall` is the high-level install pipeline. It is idempotent where practical and is protected by an instance lock.

The flow is:

1. Initialize folder structure and cache folders.
2. Create or reuse the requested Python runtime.
3. Create or reuse the per-instance Python environment.
4. Detect the AMD GPU, or use `--gfx` / cached GPU state when needed.
5. Resolve the selected channel and ROCm install plan.
6. Install ROCm/PyTorch packages and validate torch.
7. Clone/update the ComfyUI instance from the Git mirror cache.
8. Install ComfyUI `requirements.txt`.
9. Generate `extra_model_paths.yaml`.
10. Optionally link instance workflows to `shared\workflows`.
11. Install default custom nodes.
12. Install the `rocm-performance` package profile.
13. Apply applicable ComfyUI source patches.
14. Generate launchers and bind the instance path into the environment `_pth` file.
15. Write instance/environment state and optionally register with ComfyUI Desktop.
16. Run instance validation and print a summary.

Channel switching during install is manifest-driven by two optional per-family booleans in `rocm-architectures.json` (absent means `true`):

- `stableSupported: false` (`gfx101X`, `gfx103X`): `stable` automatically switches to `preview` because AMD publishes no official Windows stable release wheels for these families.
- `multiArchSupported: false` (`gfx94X`, `gfx950`): multi-arch channels (`preview`, `nightly`) automatically switch to `legacy-staging` because AMD does not publish multi-arch Windows wheels for these families yet.

## Channels And ROCm Planning

Channels live in `source\manifests\channels.json`.

| Channel | ComfyUI ref | ROCm source | Default profile | Notes |
| --- | --- | --- | --- | --- |
| `stable` | `v0.28.0` | AMD ROCm 7.2.1 direct URLs | `stable` | Pinned release wheels tagged `cp312`; requires Python 3.12 |
| `preview` | `master` | `https://rocm.nightlies.amd.com/whl-multi-arch/` | `optimized` | Promoted multi-arch wheel index; GPU selection via pip extras, not a per-family URL |
| `nightly` | `master` | `https://rocm.nightlies.amd.com/whl-staging-multi-arch/` | `optimized` | Staging multi-arch index; same mechanism as preview, more volatile |
| `legacy` | `master` | `https://rocm.nightlies.amd.com/v2/<rocmIndex>/` | `optimized` | Per-GPU-family v2 index (pre-multi-arch scheme) |
| `legacy-staging` | `master` | `https://rocm.nightlies.amd.com/v2-staging/<rocmIndex>/` | `optimized` | Per-GPU-family v2-staging index; auto-switch target for gfx94X/gfx950 |

`RocmRoll.Rocm.Resolve-RocmInstallPlan` branches on the channel's `rocm.source` field into three shapes:

- **`directUrls`** (`stable`): installs SDK and torch wheel URLs declared directly by the manifest.
- **`index`** (`legacy`, `legacy-staging`): builds a ROCm index URL from `indexBase` plus the detected family-level `rocmIndex` (e.g. `gfx110X-all`), and installs generic `torch`/`torchvision`/`torchaudio`/`rocm[libraries,devel]` package names from it.
- **`multiArch`** (`preview`, `nightly`): uses a single fixed `indexUrl` (promoted `whl-multi-arch/` or staging `whl-staging-multi-arch/`, no per-family path segment) and substitutes a `{device}` template token in the manifest's `torchPackages`/`rocmPackages` with the exact resolved GPU chip id (e.g. `torch[device-gfx1100]`, `rocm[libraries,devel,device-gfx1100]`). This is required because the multi-arch `rocm-sdk-device-*` packages are published per exact chip, not per GPU family, unlike the `index` channels' per-family folders.

Both `index` and `multiArch` channels share the same surrounding behavior:

- Preinstall `torchDependencies` from PyPI before using the ROCm/whl-multi-arch index (the `--index-url` call replaces PyPI as the default index).
- A wheelhouse cache (`.cache\wheelhouse\<rocmIndex>\` for `index`, `.cache\wheelhouse\<multiArchChip>\` for `multiArch`) is added with `--find-links` when it contains wheels.
- `allowTorchPreRelease` and `allowRocmPreRelease` can be controlled separately by channel.

`Test-RocmStateMatchesInstallPlan` treats a `multiArch` install as matching cached state only when both the channel's `rocmSource` *and* the resolved `rocmDeviceChip` are unchanged, so switching to a different exact GPU chip (e.g. moving an environment between two different RDNA 3 chips) correctly triggers reinstall even though the family-level `rocmIndex` didn't change.

### Channel Aliases And Migration

The dedicated `rdna1`/`rdna2` channels were removed when RDNA 1/2 gained multi-arch coverage. `RocmRoll.Config.Resolve-ChannelName` maps removed channel names to their replacements (`rdna1` → `preview`, `rdna2` → `preview`) and is called at every `channels.json` lookup chokepoint: `RocmRoll.Core.Invoke-FullInstall`, `RocmRoll.Rocm.Get-RocmChannelConfig` (covers repair), `RocmRoll.Launcher.Invoke-GenerateLaunchers`, and `RocmRoll.Repair.Invoke-RepairComfyUi`. Instances whose state still records an old channel therefore keep working; the canonical name is persisted on the next full install/update.

ROCm validation uses `source\scripts\validate-rocm.py` through `RocmRoll.Rocm.Invoke-ValidateRocm`. It checks torch import, torch/HIP metadata, `torch.cuda.is_available()`, device count/name, and a simple GPU tensor operation.

## GPU Architecture Mapping

GPU family mapping is stored in `source\manifests\rocm-architectures.json` and used by `RocmRoll.Hardware`.

Supported family keys currently include:

```text
gfx120X  RDNA 4
gfx1150  RDNA 3.5 / Strix Point
gfx1151  RDNA 3.5 / Strix Halo
gfx1152  RDNA 3.5 / Krackan Point
gfx1153  RDNA 3.5
gfx110X  RDNA 3
gfx103X  RDNA 2
gfx101X  RDNA 1
gfx90X   Radeon Pro VII
gfx94X   MI300 / MI325
gfx950   MI350 / MI355
```

`--gfx` accepts these family keys or exact mapped values where supported by the detector.

### Exact GPU Chip Resolution

Each family above bundles one or more physical GPU chips (e.g. `gfx110X` covers chips `gfx1100`, `gfx1101`, `gfx1102`, `gfx1103`). The `index`-source channels (`legacy`, `legacy-staging`) only need the family-level `rocmIndex` because AMD publishes one wheel folder per family. The `multiArch`-source channels (`preview`, `nightly`) need the exact chip instead, because the multi-arch `rocm-sdk-device-*` packages are published per exact chip with no per-family bundle.

Family entries also carry two optional capability flags consumed by the install auto-switch (see Install Pipeline): `stableSupported` and `multiArchSupported`, both defaulting to `true` when absent.

Each family entry in `rocm-architectures.json` carries a `chips` array (`{ "id": "gfx1100", "devices": [...] }`) splitting its `devices` list by exact chip. `RocmRoll.Hardware.Resolve-GfxChip` mirrors the existing `Resolve-GfxFamily` fragment-matching logic against the flattened `chips[].devices` lists. `Invoke-GpuDetect` returns both `gfx`/`rocmIndex` (family, used by `index`/`directUrls` channels) and `multiArchChip` (exact chip, used by the `multiArch` channels) from the same detected or overridden device. When `--gfx` overrides to a family key without a live device match, `Get-DefaultChipForFamily` picks the family's first listed chip.

`multiArchChip` is persisted in environment state (`.state\environments\environment-<name>.json`, `gpu.multiArchChip`) alongside `gpu.rocmIndex`, and is threaded through the same call paths as `rocmIndex`: full install (`RocmRoll.Core.Invoke-FullInstall`), repair (`RocmRoll.Repair.Resolve-RepairMultiArchChip`, mirroring `Resolve-RepairRocmIndex`), and launcher generation (`RocmRoll.Launcher.Invoke-GenerateLaunchers`, which reads `multiArchChip` instead of `rocmIndex` from state when the instance's channel is `multiArch`).

> Chip-to-marketing-name mappings for RDNA 3/RDNA 4/CDNA 3/CDNA 4 families are high-confidence (they map 1:1 to well-documented desktop/datacenter SKUs). The RDNA 1 (`gfx101X`) and RDNA 2 (`gfx103X`) chip splits are lower-confidence best-effort mappings and should be cross-checked against AMD/ROCm's official gfx-target documentation before being relied on for those (already-experimental) families.

## Runtime And Environment Strategy

`RocmRoll.Runtime` creates Python runtimes under `runtimes\python-<version>\`. The default is Python `3.12.10`.

Runtime creation uses:

- Python embeddable ZIP
- Full Python ZIP for `Lib`, `include`, and `libs`
- `get-pip.py`
- A generated version-specific `_pth` file

`RocmRoll.Environment` copies the runtime into an instance-specific environment named like `<instance>-py312`. Environments are independent so ROCm/PyTorch packages and custom node dependencies for one instance do not affect another.

## ComfyUI Instances And Shared Assets

`RocmRoll.ComfyUI` maintains a Git mirror cache under `.cache\git`, clones or updates instances under the configured `instances` folder, installs ComfyUI requirements, and generates `extra_model_paths.yaml`.

Default shared asset folders:

```text
shared\input
shared\output
shared\temp
shared\user
shared\models
shared\workflows
```

Model folders generated under `shared\models` include:

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

The generated launcher currently omits ComfyUI `--user-directory` because of a known upstream database initialization failure. ComfyUI user data therefore remains instance-local. The `--shared-workflows` option creates a symbolic link from `instances\<instance>\user\default\workflows` to `shared\workflows`.

## Custom Nodes And Packages

Default custom nodes are defined in `source\manifests\custom-nodes.json` and installed into each instance's `custom_nodes` folder.

Current default nodes:

- `ComfyUI-Manager`
- `CFZ-SwitchMenu`
- `CFZ-Caching`
- `ComfyUI-HFRemoteVae`
- `ComfyUI-INT8-Fast-ROCM`

Performance packages are defined in `source\manifests\package-profiles.json`. The full install applies `rocm-performance`, which currently contains:

- `triton-windows==3.7.1.post27`
- `sageattention==1.0.6`
- `bitsandbytes` from a release wheel URL, skipped on `gfx90X`, `gfx94X`, and `gfx950`
- `flash-attn` from a release wheel URL
- `amd-aiter` from a release wheel URL, dependent on `flash-attn`

Package patches live in `source\patches\sageattention\`. `RocmRoll.Packages` downloads patch replacement files into `.cache\downloads\patches`, backs up originals under `.state\patches`, and applies them to the Python environment.

## ComfyUI Source Patches

ComfyUI source patches live in `source\patches\comfyui\` as individual JSON files. `RocmRoll.ComfyPatch` applies them to instance checkouts, tracks per-instance state under `.state\patches\comfyui`, and backs up original files before editing.

Current ComfyUI patches:

| Patch ID | Scope | Purpose |
| --- | --- | --- |
| `001-avoid-comfyui-crashes-dynamic-vram` | All GPUs | Comments out `STREAM_AIMDO_CAST_BUFFERS.clear()` to avoid a dynamic VRAM crash path |
| `002-enable-pytorch-attention-vae-rdna4` | `gfx120X` | Enables PyTorch attention in VAE for RDNA 4 |

Patch CLI:

```powershell
rocmroll patch list
rocmroll patch list --instance rocm-stable
rocmroll patch apply --instance rocm-stable
rocmroll patch apply --instance rocm-stable --patch-id 001-avoid-comfyui-crashes-dynamic-vram
rocmroll patch remove --instance rocm-stable --patch-id 001-avoid-comfyui-crashes-dynamic-vram
```

Supported text operations are `comment-line`, `comment-block`, and `replace-text`.

## Execution Profiles And Launchers

Execution profiles are JSON files under the configured `profiles` folder. The generated launcher loads one profile at runtime, applies profile environment variables after fixed ROCm infrastructure variables, and appends profile launch arguments after fixed ComfyUI path/port arguments.

Profile lookup is two-tier: the configured/workspace `profiles` folder is checked first, and if a requested profile isn't found there, ROCmRoll falls back to its own built-in `<RootFolder>\profiles` (never workspace-redirectable, same precedent as `overlays\`). This matters because a workspace can fully redirect `profiles` to a location that doesn't contain ROCmRoll's shipped profiles (`stable.json`, `optimized.json`, etc.) - without the fallback, every built-in profile would be invisible once such a workspace is active. `profile create` and `profile remove` are scoped to the primary/configured folder only: new profiles are never written to the fallback, and removal can never delete a shipped built-in. Generated launchers carry both paths (`{ProfilesFolder}` and `{ProfilesRootFallback}`) and apply the same fallback at runtime.

Profile commands:

```powershell
rocmroll profile list
rocmroll profile apply --instance rocm-stable
rocmroll profile apply --instance rocm-stable --profile flash-attention
rocmroll profile show --name optimized
rocmroll profile create --name my-profile
rocmroll profile remove --name my-profile
```

Built-in profile files currently include:

| File | Intended profile | Notes |
| --- | --- | --- |
| `stable.json` | `stable` | Baseline profile; default for `stable` |
| `stable-dynamic-vram.json` | `stable-dynamic-vram` | Baseline with `--enable-dynamic-vram` |
| `optimized.json` | `optimized` | Performance profile; default for `preview`, `nightly`, `legacy`, and `legacy-staging` |
| `flash-attention.json` | `flash-attention` | Flash-Attention Triton backend, MIOpen settings, dynamic VRAM; autotuning off |
| `flash-attention-autotune.json` | `flash-attention-autotune` | Like `flash-attention` with `FLASH_ATTENTION_TRITON_AMD_AUTOTUNE=TRUE` |
| `sage-attention.json` | `sage-attention` | SageAttention backend, MIOpen settings, dynamic VRAM; autotuning off |
| `sage-attention-autotune.json` | `sage-attention-autotune` | Like `sage-attention` with `FLASH_ATTENTION_TRITON_AMD_AUTOTUNE=TRUE` |
| `performance-autotune.json` | `performance-autotune` | Aggressive MIOpen/Triton autotuning |
| `experimental.json` | local experimental content | The current file contains an object named `optimized`; do not treat it as a distinct built-in profile without checking the file |

Generated launchers are written to:

```text
launchers\<instance>.ps1
launchers\<instance>.bat
```

Fixed launch behavior includes:

- Process-local Python, pip, ROCm, HIP, Triton, and TunableOp environment variables
- PATH entries for the environment and ROCm SDK folders
- Optional `rocm-sdk.exe init`
- `--listen 127.0.0.1`
- `--port 8188` unless overridden
- `--extra-model-paths-config <instance>\extra_model_paths.yaml`
- Shared input, output, and temp directories
- Launch logs under `logs\launch`

`rocmroll instance launch --profile NAME` passes the override through to the generated launcher. Old launchers that do not support profile arguments are rejected with a repair hint.

`rocmroll profile apply --instance NAME [--profile NAME]` regenerates the launcher for the instance and refreshes the ComfyUI Desktop entry with the profile's `launchArgs` and `env`. When `--profile` is omitted the channel default is used.

## State, Logs, Locks, And Cache

State is JSON and stored under `.state` by default:

```text
.state\runtimes\runtime-<version>.json
.state\environments\environment-<name>.json
.state\instances\instance-<name>.json
.state\global.json
.state\locks\*.lock
.state\patches\
```

Logs are written under `logs\` by command area. Install creates both human-readable `.log` files and `.jsonl` files:

```text
logs\install\<yyyy-mm-dd>_<instance>_install.log
logs\install\<yyyy-mm-dd>_<instance>_install.jsonl
logs\launch\<yyyy-mm-dd>_<instance>_launch.log
```

The full install/update pipeline uses an instance lock containing PID, timestamp, and host data. A lock older than the stale threshold, or owned by a dead process, can be overridden with `--force`. Component repair/removal commands currently rely on their own guarded filesystem operations rather than the instance lock.

Cache folders are rooted at `.cache` by default:

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

Downloads use `.partial` files and are atomically renamed after successful validation.

## Diagnostics, Repair, And Desktop Registration

`RocmRoll.Doctor` runs system, GPU, cache, and instance checks. It supports scoped checks with `--system`, `--gpu`, `--cache`, and structured output with `--json`.

`RocmRoll.Repair` supports component-scoped repair:

```text
python-runtime
python-env
rocm
comfyui
custom-nodes
launchers
patches
all
```

Repair does not delete shared models, input, output, temp, workflows, or user data. Patch repair calls the managed ComfyUI patch application path and is idempotent for already-applied patches.

## Instance Removal Lifecycle

`RocmRoll.Instance` centralizes launcher, patch-artifact, Desktop-registration, state, environment, and checkout cleanup. Paths recorded in instance and environment state take precedence over conventional folder names, while `Remove-FolderTree` still enforces that recursive deletion remains inside the configured parent folder.

- `instance remove --all` removes the checkout, environment, launchers, instance/environment state, patch state/backups, and Desktop registration.
- Component removal restores managed patch backups before deleting patch metadata when `--patches` is selected without `--comfyui`.
- Removing ComfyUI, the environment, or ROCm unregisters the Desktop entry and preserves instance state with status `incomplete` plus `removedComponents`. Repair clears only the markers for components it restored and changes the instance back to `ready` once no markers remain.
- Patch-only removal does not make an otherwise ready instance incomplete.
- Shared models, input, output, temp, workflows, user data, runtimes, and caches are outside instance removal scope.

`RocmRoll.ComfyDesktop` registers installed instances in `%APPDATA%\Comfy Desktop\installations.json` when ComfyUI Desktop is present. It is a no-op when Desktop is absent, updates atomically, reuses existing Desktop IDs, and removes the Desktop entry during full removal or removal of ComfyUI/environment components.

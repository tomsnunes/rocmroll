# Declarative Instance Management

ROCmRoll supports two ways of managing instances:

- **Imperative** (simple): `instance install`/`update`/`remove`/`launch`/`repair`/`list`/`info` - you tell ROCmRoll what to do, one command at a time.
- **Declarative** (advanced): `import`/`plan`/`apply`/`destroy` - you describe the desired end state as YAML, and ROCmRoll figures out and shows you what would change before doing it. This follows the same `plan`/`apply` split as Terraform's main commands.

The declarative commands are top-level (`rocmroll plan`, not `rocmroll instance plan`) - they're a separate command family from `instance`, not subcommands of it. Under the hood, `apply` reuses the exact same imperative pipeline (`RocmRoll.Core.Invoke-FullInstall`, the function `instance install`/`instance update` call) rather than reimplementing it, so anything `instance install` can do, a declarative `apply` can do too; `destroy` similarly reuses `RocmRoll.Instance.Remove-RocmRollInstance`, the function `instance remove --all` calls.

This document also covers a related, independent fix:

1. Drift-safe `extra_model_paths.yaml` handling - updates and repairs no longer silently overwrite a file you've hand-edited.
2. The declarative layer itself: a YAML instance definition plus `import`, `plan`, `apply`, and `destroy`.

Neither requires migrating existing instances. `instance install`, `instance update`, and `instance repair` keep working exactly as documented in [README.md](../README.md); the declarative commands are additive, and both modes operate on the same recorded state.

- [extra_model_paths.yaml Preservation](#extra_model_pathsyaml-preservation)
- [Instance Overlay Folder](#instance-overlay-folder)
- [Repair Confirmation](#repair-confirmation)
- [Instance Definition YAML Schema](#instance-definition-yaml-schema)
- [YAML Subset Limitations](#yaml-subset-limitations)
- [Importing an Existing Instance](#importing-an-existing-instance)
- [Plan / Apply Workflow](#plan--apply-workflow)
- [Destroying an Instance](#destroying-an-instance)
- [Destructive Action Safeguards](#destructive-action-safeguards)
- [Exit Codes](#exit-codes)
- [Examples](#examples)

## extra_model_paths.yaml Preservation

Before this feature, every `instance update`, `comfyui update`, and `instance repair --comfyui` regenerated `extra_model_paths.yaml` unconditionally, silently discarding any manual edits.

Now:

- `instance update` (with or without `--comfyui`) and `comfyui update` **always preserve** an existing `extra_model_paths.yaml`. You'll see:

  ```text
  Preserving existing extra_model_paths.yaml during update: <path>
  ```

- If the file is missing, it's generated (overlay first, then template, then a built-in default).
- `instance repair --comfyui` regenerates the file automatically only when it still matches what ROCmRoll last wrote (or only the overlay/template source changed - safe to refresh). If the file looks hand-edited or untracked, repair asks for confirmation before replacing it; pass `--force` to skip the prompt.
- `instance install` on a brand-new instance always creates the file. Re-running install against an existing instance behaves like repair's "managed file" case: it's a no-op unless you pass `--force`.

## Instance Overlay Folder

Every per-instance override - the declarative definition, pip requirements, custom nodes, and the model-paths override - lives under one root-relative, non-`rocmroll.ini`-configurable folder:

```text
overlays\
  <instanceName>\
    <instanceName>.yaml            Declarative instance definition (see below)
    environment\
      requirements.txt             Extra pip packages
    instance\
      custom_nodes.json            Extra custom nodes
      extra_model_paths.yaml       Model-paths override
```

`requirements.txt` lives under `environment\` because it affects the Python environment; `custom_nodes.json` and `extra_model_paths.yaml` live under `instance\` because they affect the ComfyUI instance itself.

**Resolution priority: overlay folder first, then ROCmRoll's built-in default.** For `extra_model_paths.yaml` specifically this is an exclusive choice - if `overlays\<name>\instance\extra_model_paths.yaml` exists, it (not `source\templates\extra_model_paths.yaml.tpl`) is the file ROCmRoll renders (with `{SharedFolder}` substituted) into `instances\<name>\extra_model_paths.yaml` whenever the file needs to be (re)generated - fresh install, missing file, or an approved repair/apply. Without an overlay, ROCmRoll falls back to the template, then a built-in default. `requirements.txt` and `custom_nodes.json` overlays are *additive* instead: ROCmRoll always installs its own default requirements/nodes first, then the overlay's, so both apply rather than the overlay fully replacing the default set.

## Repair Confirmation

`instance repair --comfyui` classifies the on-disk file before touching it:

| Status | What it means | Repair behavior |
| --- | --- | --- |
| `missing` | File doesn't exist | Created, no prompt |
| `managed` | Matches what ROCmRoll last wrote | Regenerated automatically |
| `source-changed` | Matches what ROCmRoll last wrote, but the overlay/template changed since | Regenerated automatically |
| `custom-unknown` | Exists, but ROCmRoll has no record of ever writing it | **Confirmation required** |
| `drifted` | Exists, but no longer matches what ROCmRoll last wrote (hand-edited) | **Confirmation required** |

Skip the prompt non-interactively with `--force`:

```powershell
.\rocmroll.bat instance repair --name rocm-stable --comfyui --force
```

## Instance Definition YAML Schema

Declarative instance definitions live at `overlays\<name>\<name>.yaml` by default, or any path passed via `--file`:

```yaml
apiVersion: rocmroll.dev/v1
kind: ComfyUIInstance

metadata:
  name: rocm-stable

spec:
  channel: stable
  pythonVersion: "3.12.10"
  profile: stable-dynamic-vram
  gfx: ""
  sharedWorkflows: true

  comfyui:
    repo: https://github.com/Comfy-Org/ComfyUI.git
    ref: v0.28.0

  modelPaths:
    source: overlay
    preserveOnUpdate: true
    repairPolicy: confirm
    overlayPath: overlays/rocm-stable/instance/extra_model_paths.yaml

  customNodes:
    source: overlay
    file: overlays/rocm-stable/instance/custom_nodes.json
    pruneUnmanaged: false

  requirements:
    source: overlay
    file: overlays/rocm-stable/environment/requirements.txt

  paths:
    shared: shared
    models: shared/models
    input: shared/input
    output: shared/output
    temp: shared/temp
    user: shared/user

  updatePolicy:
    strategy: safe
    allowDestructive: false
    requirePlan: true
```

Validation rules (`RocmRoll.InstanceDefinition.Read-InstanceDefinition`):

- `apiVersion` must be `rocmroll.dev/v1`.
- `kind` must be `ComfyUIInstance`.
- `metadata.name` is required and must match `^[A-Za-z0-9_-]+$`.
- `spec.channel` is required and must resolve to a known channel (removed-channel aliases like `rdna1`/`rdna2` are accepted and mapped, same as everywhere else).
- `spec.pythonVersion` defaults to the configured runtime version (`3.12.10`) if omitted.
- `spec.profile` may be empty; the channel default profile applies at launch/apply time.
- `spec.modelPaths.preserveOnUpdate` defaults to `true`.
- `spec.modelPaths.repairPolicy` defaults to `confirm`.
- `spec.modelPaths.overlayPath` and `spec.customNodes.file` default to `overlays\<name>\instance\...` if omitted; `spec.requirements.file` defaults to `overlays\<name>\environment\requirements.txt`.
- Fields not recognized by the schema produce a warning (printed before the plan/apply/destroy output), not a fatal error.

## YAML Subset Limitations

PowerShell 5.1 has no built-in YAML support, and this project avoids external module dependencies. `RocmRoll.YamlLite` implements only what the schema above needs:

- Supported: nested block mappings, string/boolean/quoted scalars, `#` comments, blank lines.
- **Not supported**: YAML lists (`- item`), flow style (`{}`/`[]`), anchors/aliases, multi-document files, tab indentation. Any of these produce a clear `ROCMROLL-YAML-*` error rather than a silent mis-parse.

This is why nothing in the schema is a list - every "multiple things" concept (custom nodes, requirements) is expressed as a path to an existing JSON/text file instead.

## Importing an Existing Instance

Any instance created the imperative way (`instance install`) can be brought under declarative management without reinstalling anything:

```powershell
.\rocmroll.bat import --name rocm-stable
```

This reverse-engineers `overlays\rocm-stable\rocm-stable.yaml` from the instance's recorded state and filesystem:

- `spec.channel`, `spec.comfyui.ref`/`repo` come from `.state\instances\instance-rocm-stable.json`.
- `spec.pythonVersion` and `spec.gfx` come from the bound environment's state.
- `spec.modelPaths.source` is `overlay` if `overlays\rocm-stable\instance\extra_model_paths.yaml` exists, otherwise `template`. `spec.customNodes.source`/`spec.requirements.source` follow the same rule against `overlays\rocm-stable\instance\custom_nodes.json` and `overlays\rocm-stable\environment\requirements.txt` respectively.
- `spec.sharedWorkflows` is detected from whether `instances\rocm-stable\user\default\workflows` is actually a symlink.
- `spec.paths.*` are filled in with the currently resolved workspace paths, so a plan right after import doesn't report a spurious paths mismatch.
- `spec.profile` is always written as `""` (empty). The profile an instance was installed or launched with isn't persisted anywhere in instance state, so it can't be recovered - an empty profile resolves to the channel default, which is the closest safe guess. Set it explicitly if the instance is actually running a non-default profile.
- `spec.updatePolicy` is written with safe defaults (`allowDestructive: false`, `requirePlan: true`).

`--output PATH` writes somewhere other than the default `overlays\<name>\<name>.yaml`; `--force` overwrites an existing definition file (import refuses to overwrite by default, same as any other file ROCmRoll doesn't want to silently clobber).

After writing the file, import immediately runs a plan against it and prints the result, so you can see at a glance whether the generated definition matches reality - expect mostly `NOOP`/`PRESERVE` actions. Review the file (especially `spec.profile`) before running `apply` against it.

## Plan / Apply Workflow

```powershell
.\rocmroll.bat plan --file .\overlays\rocm-stable\rocm-stable.yaml
.\rocmroll.bat apply --file .\overlays\rocm-stable\rocm-stable.yaml
```

`--name NAME` can be used instead of `--file PATH` once a definition exists at the default `overlays\NAME\NAME.yaml` location.

`plan` compares three layers and classifies each finding:

1. **Declared** - the YAML definition (`spec.channel`, `spec.pythonVersion`, `spec.comfyui.ref`, ...).
2. **Recorded** - ROCmRoll's own state (`.state\instances\instance-<name>.json`, plus the bound environment's state, including which files it considers itself to manage).
3. **Actual** - the real filesystem/runtime (does the checkout exist, does the environment folder exist, is there a launcher, what's actually in `custom_nodes`).

Action ids: `modelPaths.extra_model_paths`, `comfyui.source`, `channel`, `pythonVersion`, `environment`, `launcher`, `customNodes.unmanaged`, `paths.shared`. Action types: `NOOP`, `CREATE`, `UPDATE`, `REPAIR`, `REPLACE`, `DELETE`, `PRESERVE`, `WARNING`, `DESTRUCTIVE`. Every action also carries a `destructive` flag independent of its type.

Example output:

```text
Plan: rocm-stable

  PRESERVE  modelPaths.extra_model_paths
            Existing file will be preserved during update.

  UPDATE    comfyui.source
            Current ref: master
            Desired ref: v0.28.0

  NOOP      environment
            Python environment present.

  WARNING   customNodes.unmanaged
            custom_nodes folder contains unmanaged node(s): MyExtraNode. pruneUnmanaged=false - not modified by apply.

Summary:
  0 to create, 1 to update, 0 to replace, 0 to delete, 1 preserved, 1 warning(s), 0 destructive.
```

A brand-new instance (nothing installed yet) plans as a full create - `apply` against this plan runs the same pipeline `instance install` would:

```text
Plan: rocm-stable

  CREATE    modelPaths.extra_model_paths
            extra_model_paths.yaml does not exist yet.

  CREATE    comfyui.source
            ComfyUI checkout does not exist yet.

  CREATE    environment
            Python environment/runtime not found for this instance.

  CREATE    launcher
            Launcher not found.

Summary:
  4 to create, 0 to update, 0 to replace, 0 to delete, 0 preserved, 0 warning(s), 0 destructive.
```

Save a plan as JSON and apply it later:

```powershell
.\rocmroll.bat plan --file .\overlays\rocm-stable\rocm-stable.yaml --output .\.state\plans\rocm-stable.plan.json
.\rocmroll.bat apply --plan .\.state\plans\rocm-stable.plan.json --file .\overlays\rocm-stable\rocm-stable.yaml
```

If state or the definition changed since the plan was saved, `apply` warns that the saved plan may be stale rather than applying it blindly. A plan can also be applied directly without a separate save step - `apply --file ...` alone computes and applies in one go, same as `apply --plan ...` does for a saved one.

**What `apply` actually executes.** `apply` is capable of every action `instance install`/`instance update` can perform, because for anything beyond the lightweight case it calls the exact same underlying function:

- `extra_model_paths.yaml` (`modelPaths.extra_model_paths`) is always reconciled directly first - create it, refresh a `managed`/`source-changed` file, or (with `--allow-destructive`) replace a `custom-unknown`/`drifted` one.
- If the plan has any pending `CREATE`/`UPDATE` for `environment`, `channel`, `pythonVersion`, or `comfyui.source`, `apply` runs the full install/update pipeline (`Invoke-FullInstall`) once - the same call `instance install` (brand-new instance) or `instance update` (existing instance) makes. That single call creates the Python runtime/environment, detects the GPU, installs ROCm/PyTorch for the declared channel, clones/updates the ComfyUI checkout, installs requirements/custom nodes/performance packages/patches, and regenerates launchers - converging the instance to the declared state exactly like re-running install/update imperatively would.
- If nothing pipeline-level is pending and only the launcher is missing, `apply` regenerates just the launcher, without paying for the full pipeline.

Informational-only findings (unmanaged custom nodes, a declared `paths.shared` mismatch) are `WARNING`s and are never auto-applied - no auto-pruning of custom nodes, no deleting shared data; see Destructive Action Safeguards below.

## Destroying an Instance

```powershell
.\rocmroll.bat destroy --name rocm-stable
.\rocmroll.bat destroy --name rocm-stable --dry-run
.\rocmroll.bat destroy --name rocm-stable --auto-approve
```

`destroy` tears down everything a full `instance install` creates - the ComfyUI checkout, the Python environment, generated launchers, patch state, and recorded instance/environment state - by calling `RocmRoll.Instance.Remove-RocmRollInstance`, the same function `instance remove --all` uses.

Shared assets (models, input, output, temp, user data, workflows) and the instance's `overlays\<name>\` folder (its declarative definition, `requirements.txt`, `custom_nodes.json`, and any `extra_model_paths.yaml` overlay) are never touched, so re-running `apply` against the same definition later recreates the instance from scratch.

`destroy` always shows a preview first (`DELETE` for what's removed, `PRESERVE` for what's kept), then - because this is irreversible - requires typing the instance's exact name to confirm, not just `y`/`N`. Pass `--auto-approve` to skip the prompt for scripted/CI use, or `--dry-run` to see the preview without confirming or deleting anything. `destroy` only tears down a whole instance; removing a single component (environment, ComfyUI, ROCm, patches) is still `instance remove --environment`/`--comfyui`/etc.

## Destructive Action Safeguards

An action is `destructive` when applying it would replace content ROCmRoll doesn't already own an authoritative copy of - right now, that's a `custom-unknown`/`drifted` `extra_model_paths.yaml`.

- `apply` refuses to execute any destructive action unless you pass `--allow-destructive`, or the definition sets `spec.updatePolicy.allowDestructive: true`.
- Non-destructive create/update/repair actions still show the plan and ask for confirmation unless `--auto-approve`, or `spec.updatePolicy.requirePlan: false`.
- `destroy` is entirely destructive by nature, so instead of an `--allow-destructive` flag it requires typing the instance's exact name to confirm, unless `--auto-approve` is passed.
- `--dry-run` (`apply`/`destroy`) shows what would happen without changing anything or asking for confirmation.
- Shared folders (models, input, output, temp, workflows, user data) are never deleted by any of this - the plan/apply/destroy engine doesn't touch them at all.

## Exit Codes

`apply` exits `3` if any destructive action was blocked (missing `--allow-destructive`), `1` on a command error, `0` otherwise.

`destroy` exits `0` on success (destroyed, dry-run, or nothing to destroy), `1` if cancelled (typed name didn't match) or the instance couldn't be resolved.

## Examples

Bring an existing, already-installed instance under declarative management, then verify the generated definition matches reality:

```powershell
.\rocmroll.bat import --name rocm-stable
.\rocmroll.bat plan --name rocm-stable
```

Plan and apply a brand-new definition, allowing destructive changes because you know the overlay file is intentional:

```powershell
.\rocmroll.bat plan --file .\overlays\rocm-stable\rocm-stable.yaml
.\rocmroll.bat apply --file .\overlays\rocm-stable\rocm-stable.yaml --allow-destructive
```

Check for pending changes in CI without changing anything, failing the build only if something's pending:

```powershell
$planJson = .\rocmroll.bat plan --name rocm-stable --json | ConvertFrom-Json
$changed = $planJson.actions | Where-Object { $_.type -notin @('NOOP', 'PRESERVE') }
if ($changed) { throw "Instance rocm-stable has pending changes." }
```

Non-interactive apply for a scheduled task, allowing only safe changes:

```powershell
.\rocmroll.bat apply --name rocm-stable --auto-approve
```

Tear down an instance once you're done with it, non-interactively:

```powershell
.\rocmroll.bat destroy --name rocm-stable --auto-approve
```

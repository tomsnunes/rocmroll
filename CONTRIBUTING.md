# Contributing to ComfyUI ROCmRoll

Thank you for your interest in contributing. ROCmRoll is a spec-driven project — features are designed before they are implemented. This keeps the codebase intentional and the architecture coherent.

---

## Table of Contents

- [Ways to Contribute](#ways-to-contribute)
- [Reporting Bugs](#reporting-bugs)
- [Proposing Features](#proposing-features)
- [Development Setup](#development-setup)
- [Code Style](#code-style)
- [Pull Request Guidelines](#pull-request-guidelines)
- [Adding GPU Support](#adding-gpu-support)
- [Adding Custom Nodes](#adding-custom-nodes)
- [Updating Manifests](#updating-manifests)

---

## Ways to Contribute

- **Bug reports** — Reproducible issues with doctor output and logs attached.
- **GPU additions** — Add your GPU to `source\manifests\rocm-architectures.json` if it is missing.
- **Manifest updates** — Package version bumps, new custom nodes, architecture corrections.
- **Documentation** — Fixes, clarifications, translations.
- **Feature specs** — Write a spec for a feature you want and discuss it before implementing.
- **Code** — Implement an accepted spec or fix a confirmed bug.

---

## Reporting Bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Always include:

1. Output of `.\rocmroll.bat doctor --name <name> --json`
2. The install log from `logs\install\`
3. Your GPU model and GFX family
4. The channel you are using (stable/nightly)
5. Steps to reproduce

Without this information, bug reports cannot be triaged quickly.

---

## Proposing Features

ROCmRoll uses a spec-first workflow:

1. **Open a Discussion** describing the problem and your proposed solution.
2. If there is community interest, write a spec document in `docs/specs/` following the existing format. Each spec must include: Status, Context, Goals, Non-goals, User stories, Functional requirements, Command examples, State schema, Error cases, and Acceptance criteria.
3. The spec is reviewed and marked **Accepted**.
4. Implementation begins after acceptance.

This prevents half-finished features and keeps the architecture reviewable.

---

## Development Setup

ROCmRoll has no build step. The source is the runtime.

Requirements:

- Windows 10/11
- PowerShell 5.1 or newer
- Git for Windows
- An AMD GPU (for integration testing) or a manual `--gfx` override for dry runs

Clone the repository:

```powershell
git clone https://github.com/<owner>/rocmroll C:\Platform\ai
cd C:\Platform\ai
```

Syntax-check all PowerShell modules:

```powershell
Get-ChildItem .\source\modules\*.psm1 | ForEach-Object {
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize((Get-Content $_.FullName -Raw), [ref]$errors) | Out-Null
    if ($errors) { Write-Warning "$($_.Name): $($errors.Count) parse error(s)" }
    else { Write-Host "$($_.Name): OK" }
}
```

Run system diagnostics:

```powershell
.\rocmroll.bat doctor --system
.\rocmroll.bat doctor --gpu
```

---

## Code Style

ROCmRoll is written in PowerShell 5.1-compatible code. Follow these conventions:

**Naming**

- Functions: `Verb-RocmRollNoun` or `Verb-Noun` when scope is clear from the module name.
- Parameters: `$PascalCase`
- Local variables: `$camelCase`
- Config keys: `PascalCase` (matching the `$cfg` object)

**Module structure**

- Every module starts with `#Requires -Version 5.1`, `Set-StrictMode -Version Latest`, and `$ErrorActionPreference = 'Stop'`.
- Import dependencies at the top of each exported function, not at module scope, to allow independent module use.
- End every module with an explicit `Export-ModuleMember` listing.

**Paths**

- Never hardcode paths. All paths go through `Get-Config`.
- Use `Join-Path` — never string concatenation with `\`.
- Forward slashes in generated YAML, backslashes everywhere else.

**Error handling**

- Use `throw "ROCMROLL-COMPONENT-NNN: <message>"` for fatal errors.
- Log warnings with `Write-LogWarn`; log successes with `Write-LogSuccess`.
- Never swallow errors silently unless the failure is explicitly optional and documented.

**Comments**

- Only add a comment when the **why** is non-obvious.
- Do not comment what the code does — good names do that.

**No new files without a spec** for significant features. Small fixes and manifest updates do not need specs.

---

## Pull Request Guidelines

1. **One concern per PR.** A bug fix and a refactor are two PRs.
2. **Reference the spec** or issue your PR addresses.
3. **Test on at least one real AMD GPU** when the change touches GPU detection, ROCm install, or the launch path.
4. **Update documentation** — if you change a command, flag, path, or manifest schema, update `README.md`, `docs/architecture.md`, or the relevant spec.
5. **Run the syntax check** before opening a PR (see [Development Setup](#development-setup)).
6. **Fill in the PR template.** PRs without a description of what was tested will be asked for more information.

PR titles should use conventional commit style:

```
feat: add --shared-workflows flag to repair command
fix: derive InputFolder from SharedFolder in Config
docs: update architecture.md section 6 for shared layout
chore: bump sageattention to 1.0.7 in package-profiles.json
```

---

## Adding GPU Support

1. Find your GPU's GFX family from the AMD ROCm documentation.
2. Open `source\manifests\rocm-architectures.json`.
3. Add your device name to the `"devices"` array of the matching GFX family.
4. If your GPU needs a new GFX family entry, add one following the existing schema.
5. Test with `.\rocmroll.bat doctor --gpu` and a full install.
6. Submit a PR with the manifest change only — one PR per family if multiple families are being added.

---

## Adding Custom Nodes

Default custom nodes are defined in `source\manifests\custom-nodes.json`.

To propose a new default node:

1. The node must have a public Git repository.
2. It must work on AMD GPUs with ROCm.
3. It must not require root/admin access to install.
4. Open an issue with the node name, repo URL, and a description of what it adds.
5. If accepted, add it to the manifest and submit a PR.

---

## Updating Manifests

Manifest files live in `source\manifests\`. They drive behaviour without code changes:

| Manifest | What it controls |
| --- | --- |
| `channels.json` | Channel definitions, ComfyUI refs, ROCm sources, default profiles |
| `python-runtimes.json` | Python version URLs and checksums |
| `rocm-architectures.json` | GPU family to ROCm index mapping |
| `package-profiles.json` | Acceleration package lists and wheel URLs |
| `custom-nodes.json` | Default custom node repos and refs |
| `patches.json` | Reversible source patches for packages |

Manifest-only PRs (version bumps, URL updates, new GPU entries) are the fastest to review and merge. Include the reason for the change in the PR description.

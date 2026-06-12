"""
gpu_detect.py - ROCmRoll GPU detection script for Windows AMD GPUs.

Usage:
    python gpu_detect.py [--json] [--quiet] [--gfx <gfxXXX>] [--arch-manifest <path>]

Outputs machine-readable JSON to stdout.
Diagnostics go to stderr.
Exit codes:
    0 - GPU detected and supported
    1 - GPU detected but unsupported or unknown architecture
    2 - No AMD GPU detected
    3 - Detection error
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Architecture table (fallback - primary source is rocm-architectures.json)
# ---------------------------------------------------------------------------

_BUILTIN_ARCH_TABLE: dict[str, dict] = {
    "gfx120X": {
        "index": "gfx120X-all",
        "architecture": "RDNA 4",
        "requiresPreRelease": True,
        "supported": True,
        "devices": ["RX 9060", "RX 9070", "RX 9070 XT"],
    },
    "gfx1151": {
        "index": "gfx1151",
        "architecture": "RDNA 3.5 / Strix Halo",
        "requiresPreRelease": True,
        "supported": True,
        "devices": ["Strix Halo", "Radeon 8060S", "Radeon 8050S", "Radeon 8040S", "Radeon 880M"],
    },
    "gfx110X": {
        "index": "gfx110X-all",
        "architecture": "RDNA 3",
        "requiresPreRelease": True,
        "supported": True,
        "devices": ["RX 7900", "RX 7800", "RX 7700", "RX 7600", "Radeon 780M"],
    },
    "gfx103X": {
        "index": "gfx103X-dgpu",
        "architecture": "RDNA 2",
        "requiresPreRelease": False,
        "supported": True,
        "devices": ["RX 6900", "RX 6800", "RX 6700", "RX 6600", "RX 6500"],
    },
    "gfx101X": {
        "index": "gfx101X-dgpu",
        "architecture": "RDNA 1",
        "requiresPreRelease": False,
        "supported": True,
        "devices": ["RX 5700", "RX 5600", "RX 5500"],
    },
}

# Map of device name substrings to gfx families (lower-case key)
_DEVICE_NAME_TO_GFX: list[tuple[str, str]] = [
    # RDNA 4 (gfx120X)
    ("rx 9070 xt", "gfx120X"),
    ("rx 9070",    "gfx120X"),
    ("rx 9060",    "gfx120X"),
    # RDNA 3.5 Strix Halo (gfx1151)
    ("strix halo", "gfx1151"),
    ("radeon 8060s", "gfx1151"),
    ("radeon 8050s", "gfx1151"),
    ("radeon 8040s", "gfx1151"),
    ("radeon 880m",  "gfx1151"),
    # RDNA 3 (gfx110X)
    ("rx 7900", "gfx110X"),
    ("rx 7800", "gfx110X"),
    ("rx 7700", "gfx110X"),
    ("rx 7600", "gfx110X"),
    ("radeon 780m", "gfx110X"),
    # RDNA 2 (gfx103X)
    ("rx 6900", "gfx103X"),
    ("rx 6800", "gfx103X"),
    ("rx 6700", "gfx103X"),
    ("rx 6600", "gfx103X"),
    ("rx 6500", "gfx103X"),
    # RDNA 1 (gfx101X)
    ("rx 5700", "gfx101X"),
    ("rx 5600", "gfx101X"),
    ("rx 5500", "gfx101X"),
]


def _log(msg: str, quiet: bool = False) -> None:
    """Write diagnostic message to stderr."""
    if not quiet:
        print(f"[gpu_detect] {msg}", file=sys.stderr)


def _load_arch_manifest(path: Optional[str], quiet: bool) -> dict:
    if path and os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except Exception as exc:
            _log(f"Failed to load arch manifest '{path}': {exc}", quiet)
    # Try sibling location relative to this script
    default = Path(__file__).parent.parent / "manifests" / "rocm-architectures.json"
    if default.is_file():
        try:
            with open(default, encoding="utf-8") as fh:
                return json.load(fh)
        except Exception as exc:
            _log(f"Failed to load default arch manifest: {exc}", quiet)
    return _BUILTIN_ARCH_TABLE


def _map_name_to_gfx(device_name: str) -> Optional[str]:
    lower = device_name.lower()
    for fragment, gfx in _DEVICE_NAME_TO_GFX:
        if fragment in lower:
            return gfx
    return None


def _detect_via_cim(quiet: bool) -> list[dict]:
    """Use PowerShell CIM to list video controllers."""
    script = (
        "Get-CimInstance Win32_VideoController | "
        "Select-Object Name,AdapterCompatibility,PNPDeviceID | "
        "ConvertTo-Json -Depth 2"
    )
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode != 0:
            _log(f"CIM query failed (rc={result.returncode}): {result.stderr.strip()}", quiet)
            return []
        data = json.loads(result.stdout.strip())
        if isinstance(data, dict):
            data = [data]
        return data if isinstance(data, list) else []
    except Exception as exc:
        _log(f"CIM detection error: {exc}", quiet)
        return []


def _detect_via_pnp(quiet: bool) -> list[dict]:
    """Fallback: PowerShell PnP device query."""
    script = (
        "Get-PnpDevice -Class Display -Status OK 2>$null | "
        "Select-Object FriendlyName,Manufacturer,InstanceId | "
        "ConvertTo-Json -Depth 2"
    )
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode != 0:
            return []
        data = json.loads(result.stdout.strip())
        if isinstance(data, dict):
            data = [data]
        return [{"Name": d.get("FriendlyName", ""), "AdapterCompatibility": d.get("Manufacturer", "")} for d in data] if isinstance(data, list) else []
    except Exception as exc:
        _log(f"PnP detection error: {exc}", quiet)
        return []


def _detect_via_wmic(quiet: bool) -> list[dict]:
    """Legacy WMIC fallback."""
    try:
        result = subprocess.run(
            ["wmic", "path", "Win32_VideoController", "get", "Name,AdapterCompatibility", "/format:csv"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        rows = []
        for line in result.stdout.splitlines():
            parts = line.split(",")
            if len(parts) >= 3:
                rows.append({"AdapterCompatibility": parts[1].strip(), "Name": parts[2].strip()})
        return rows
    except Exception as exc:
        _log(f"WMIC detection error: {exc}", quiet)
        return []


def _find_amd_gpu(candidates: list[dict]) -> Optional[dict]:
    """Return first AMD GPU entry from a list of video controller records."""
    for entry in candidates:
        name = str(entry.get("Name", "")).strip()
        compat = str(entry.get("AdapterCompatibility", "")).strip()
        if "amd" in name.lower() or "radeon" in name.lower() or "amd" in compat.lower():
            return {"name": name, "vendor": compat or "AMD"}
    return None


def detect(quiet: bool, arch_manifest_path: Optional[str], gfx_override: Optional[str]) -> dict:
    arch_table = _load_arch_manifest(arch_manifest_path, quiet)

    if gfx_override:
        _log(f"Using manual GFX override: {gfx_override}", quiet)
        arch_info = arch_table.get(gfx_override, {})
        return {
            "detected": True,
            "supported": arch_info.get("supported", False),
            "name": f"Manual override ({gfx_override})",
            "vendor": "AMD",
            "architecture": arch_info.get("architecture", "Unknown"),
            "gfx": gfx_override,
            "rocmIndex": arch_info.get("index", ""),
            "requiresPreRelease": arch_info.get("requiresPreRelease", False),
            "detectionMethod": "override",
        }

    gpu: Optional[dict] = None
    method = "none"

    _log("Trying CIM detection...", quiet)
    candidates = _detect_via_cim(quiet)
    gpu = _find_amd_gpu(candidates)
    if gpu:
        method = "cim"

    if not gpu:
        _log("Trying PnP detection...", quiet)
        candidates = _detect_via_pnp(quiet)
        gpu = _find_amd_gpu(candidates)
        if gpu:
            method = "pnp"

    if not gpu:
        _log("Trying WMIC detection...", quiet)
        candidates = _detect_via_wmic(quiet)
        gpu = _find_amd_gpu(candidates)
        if gpu:
            method = "wmic"

    if not gpu:
        return {
            "detected": False,
            "supported": False,
            "name": None,
            "vendor": None,
            "architecture": None,
            "gfx": None,
            "rocmIndex": None,
            "requiresPreRelease": False,
            "detectionMethod": "none",
            "error": "No AMD GPU found",
        }

    name = gpu["name"]
    gfx = _map_name_to_gfx(name)
    arch_info = arch_table.get(gfx, {}) if gfx else {}

    return {
        "detected": True,
        "supported": arch_info.get("supported", False),
        "name": name,
        "vendor": gpu.get("vendor", "AMD"),
        "architecture": arch_info.get("architecture", "Unknown"),
        "gfx": gfx,
        "rocmIndex": arch_info.get("index", None),
        "requiresPreRelease": arch_info.get("requiresPreRelease", False),
        "detectionMethod": method,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="ROCmRoll GPU detection - outputs JSON to stdout, diagnostics to stderr."
    )
    parser.add_argument("--json",         action="store_true", help="Emit JSON output (always on; kept for compatibility)")
    parser.add_argument("--quiet",        action="store_true", help="Suppress stderr diagnostics")
    parser.add_argument("--gfx",          metavar="GFX",       help="Manual GFX family override, e.g. gfx120X")
    parser.add_argument("--arch-manifest", metavar="PATH",     help="Path to rocm-architectures.json")
    args = parser.parse_args()

    try:
        result = detect(
            quiet=args.quiet,
            arch_manifest_path=args.arch_manifest,
            gfx_override=args.gfx,
        )
        print(json.dumps(result, indent=2))
        if not result.get("detected"):
            return 2
        if not result.get("supported"):
            return 1
        return 0
    except Exception as exc:
        error_out = {"detected": False, "supported": False, "error": str(exc)}
        print(json.dumps(error_out, indent=2))
        return 3


if __name__ == "__main__":
    sys.exit(main())

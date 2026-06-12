"""
verify_rocm.py - ROCmRoll ROCm/PyTorch validation script.

Usage:
    python verify_rocm.py [--json] [--quiet]

Outputs machine-readable JSON to stdout.
Exit codes:
    0 - All checks passed
    1 - One or more checks failed
    2 - torch not importable
"""

import argparse
import json
import sys
from typing import Any


def _check(name: str, fn) -> dict[str, Any]:
    try:
        value = fn()
        return {"check": name, "passed": True, "value": str(value)}
    except Exception as exc:
        return {"check": name, "passed": False, "error": str(exc)}


def run_checks(quiet: bool) -> dict[str, Any]:
    results: list[dict] = []
    passed_all = True

    # 1. torch importable
    try:
        import torch  # noqa: PLC0415
    except ImportError as exc:
        result = {
            "passed": False,
            "torchImportable": False,
            "error": str(exc),
            "checks": [],
        }
        if not quiet:
            print(f"[verify_rocm] torch import failed: {exc}", file=sys.stderr)
        return result

    results.append({"check": "torch_importable", "passed": True, "value": "ok"})

    # 2. torch version
    results.append(_check("torch_version", lambda: torch.__version__))

    # 3. cuda available (ROCm exposes via CUDA compat layer)
    cuda_avail = _check("cuda_available", lambda: torch.cuda.is_available())
    results.append(cuda_avail)
    if not cuda_avail.get("value", "False") in ("True", "true", True):
        passed_all = False

    # 4. HIP version
    hip_check = _check("hip_version", lambda: torch.version.hip)
    results.append(hip_check)
    if not hip_check.get("passed") or not hip_check.get("value"):
        passed_all = False

    # 5. Device count
    results.append(_check("device_count", lambda: torch.cuda.device_count()))

    # 6. Device name (if available)
    def _device_name():
        if torch.cuda.is_available() and torch.cuda.device_count() > 0:
            return torch.cuda.get_device_name(0)
        return "N/A"

    results.append(_check("device_name", _device_name))

    # 7. Simple tensor op on GPU
    def _tensor_op():
        if torch.cuda.is_available():
            t = torch.tensor([1.0, 2.0], device="cuda")
            return float(t.sum().item())
        return "skipped (no CUDA)"

    tensor_check = _check("tensor_op", _tensor_op)
    results.append(tensor_check)

    for r in results:
        if not r.get("passed", True):
            passed_all = False

    return {
        "passed": passed_all,
        "torchImportable": True,
        "torchVersion": torch.__version__,
        "hipVersion": getattr(torch.version, "hip", None),
        "cudaAvailable": torch.cuda.is_available(),
        "deviceCount": torch.cuda.device_count() if torch.cuda.is_available() else 0,
        "checks": results,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="ROCmRoll ROCm/PyTorch validation")
    parser.add_argument("--json",  action="store_true", help="Emit JSON (always on; kept for compatibility)")
    parser.add_argument("--quiet", action="store_true", help="Suppress stderr output")
    args = parser.parse_args()

    result = run_checks(quiet=args.quiet)
    print(json.dumps(result, indent=2))
    return 0 if result.get("passed") else (2 if not result.get("torchImportable") else 1)


if __name__ == "__main__":
    sys.exit(main())

import json, os, sys

# rocm_sdk's offload-arch GPU discovery spawns an unquoted exe path and breaks
# on space-containing install paths; pre-seed the target family it would have
# detected, but only if the installed distribution actually offers it.
_raw_index = sys.argv[1] if len(sys.argv) > 1 else ""
# RocmIndex includes a suffix (gfx103X-all, gfx101X-dgpu, gfx110X-all); strip it
# to get the plain family name that AVAILABLE_TARGET_FAMILIES carries.
target_family = _raw_index.split('-')[0] if _raw_index else ""
if target_family and not os.environ.get("ROCM_SDK_TARGET_FAMILY"):
    try:
        from rocm_sdk import _dist_info
        if target_family in _dist_info.AVAILABLE_TARGET_FAMILIES:
            os.environ["ROCM_SDK_TARGET_FAMILY"] = target_family
    except Exception:
        pass

try:
    import torch
except Exception as exc:
    print(json.dumps({"passed": False, "torchImportable": False, "error": str(exc), "checks": []}))
    sys.exit(2)

def chk(name, fn):
    try:
        return {"check": name, "passed": True, "value": str(fn())}
    except Exception as exc:
        return {"check": name, "passed": False, "error": str(exc)}

checks = [{"check": "torch_importable", "passed": True, "value": "ok"}]
checks.append(chk("torch_version", lambda: torch.__version__))

ca = chk("cuda_available", lambda: torch.cuda.is_available())
checks.append(ca)

hc = chk("hip_version", lambda: torch.version.hip)
checks.append(hc)

checks.append(chk("device_count", lambda: torch.cuda.device_count()))
checks.append(chk("device_name", lambda: torch.cuda.get_device_name(0) if torch.cuda.is_available() and torch.cuda.device_count() > 0 else "N/A"))

def tensor_op():
    if torch.cuda.is_available():
        t = torch.tensor([1.0, 2.0], device="cuda")
        return float(t.sum().item())
    return "skipped (no CUDA)"

checks.append(chk("tensor_op", tensor_op))

passed_all = (
    ca.get("value") in ("True", "true") and
    hc.get("passed") and hc.get("value") and
    all(r.get("passed", True) for r in checks)
)

def _pkg_ver(name):
    try:
        import importlib.metadata
        return importlib.metadata.version(name)
    except Exception:
        return None

tv_ver = _pkg_ver("torchvision")
ta_ver = _pkg_ver("torchaudio")

print(json.dumps({
    "passed": passed_all,
    "torchImportable": True,
    "torchVersion": torch.__version__,
    "torchvisionVersion": tv_ver,
    "torchaudioVersion": ta_ver,
    "hipVersion": getattr(torch.version, "hip", None),
    "cudaAvailable": torch.cuda.is_available(),
    "deviceCount": torch.cuda.device_count() if torch.cuda.is_available() else 0,
    "checks": checks,
}))

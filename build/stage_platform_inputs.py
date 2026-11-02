"""Copy locked platform inputs and localize asset paths; never invoke EDA."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def prepare(root, out):
    root, out = Path(root).resolve(), Path(out).resolve()
    if out.exists():
        raise FileExistsError("Use a fresh output directory")
    inventory = json.loads((root / "platform/inputs_inventory.json").read_text(encoding="utf-8"))
    bd = json.loads((root / "platform/seed/system.bd").read_text(encoding="utf-8"))
    files = sorted((root / "platform/inputs").iterdir())
    if not files or any(not p.is_file() or p.is_symlink() for p in files):
        raise ValueError("Expected flat platform input files")
    stub = root / "platform/seed/legacy_core_stub.v"
    if not stub.is_file() or any(p.name == "ofdm_development_core.v" for p in files):
        raise ValueError("Missing or conflicting core stub")
    for row in inventory["external_file_fields"]:
        name = row["package_asset"]
        parts = PurePosixPath(name).parts
        if len(parts) != 3 or parts[:2] != ("platform", "inputs") or ".." in parts or "\\" in name:
            raise ValueError("Asset must be a flat platform/inputs file")
        if root / name not in files:
            raise ValueError("Required input asset missing")
        target = bd
        keys = row["json_keys"]
        for key in keys[:-1]:
            target = target[key]
        if target[keys[-1]] != row["historical_value"]:
            raise ValueError("Seed BD differs at recorded file field")
        target[keys[-1]] = (out / "inputs" / parts[-1]).as_posix()
    inputs = out / "inputs"
    inputs.mkdir(parents=True, exist_ok=False)
    pins = []
    for source in files + [stub]:
        target = inputs / ("ofdm_development_core.v" if source == stub else source.name)
        shutil.copyfile(source, target)
        original = digest(source)
        if digest(target) != original:
            raise OSError("Copied input differs: " + target.name)
        pins.append({"package_path": source.relative_to(root).as_posix(),
                     "staged_path": target.relative_to(out).as_posix(), "sha256": original})
    (inputs / "system.bd").write_text(json.dumps(bd, indent=2) + "\n", encoding="utf-8")
    result = {"status": "PLATFORM_INPUTS_LOCALIZED_NOT_BD_VALIDATED", "eda_executed": False,
              "localized_fields": len(inventory["external_file_fields"]), "copied_files": pins,
              "staged_bd_sha256": digest(inputs / "system.bd"),
              "remaining_native_steps": [s for s in inventory["required_native_deltas"]
                                         if not s.startswith("Localize ")]}
    (out / "preparation.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1] / "src")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.root, args.out)
    print(json.dumps({"status": result["status"], "localized_fields": result["localized_fields"],
                      "copied_files": len(result["copied_files"]), "eda_executed": False}))


if __name__ == "__main__":
    main()

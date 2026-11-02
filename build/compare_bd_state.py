"""Compare persisted BD/XCI configuration of two Vivado projects; never invoke EDA.

Gate: every IP instance, its VLNV/revision, every parameter value and enabled
flag, every boundary port and the whole BD JSON must match. Two classes are
reported as notes, not failures:
  * numeric_format: both strings are plain decimal numbers with exactly equal
    value (e.g. 1e+08 vs 100000000, 100.0 vs 100); hex/other strings stay exact;
  * metadata: bookkeeping fields beside an equal value (resolve_type, value_src,
    value_permission, format, usage, ...) and a dropped XCI cell_name;
  * disabled_param: an XCI parameter whose value differs while it is
    enabled=false on BOTH sides (Vivado does not use it; model parameters,
    which drive generated HDL, are still compared strictly);
  * bd_param_echo: a BD component parameter recorded on only one side whose
    value equals that IP's persisted reference XCI value (BD stores a variable
    subset of the XCI parameters).
Location fields (generated/shared output directories) are ignored by name.
"""
import argparse
from decimal import Decimal, InvalidOperation
import json
from pathlib import Path
import re
import sys

DECIMAL = re.compile(r"^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$")
LOCATION_RUNTIME = {"OUTPUTDIR", "SHAREDDIR"}
GATED_FIELDS = ("value", "enabled")


def equal_value(a, b):
    """Return 'exact', 'numeric_format' or None."""
    if a == b:
        return "exact"
    if isinstance(a, str) and isinstance(b, str) and DECIMAL.match(a) and DECIMAL.match(b):
        try:
            if Decimal(a) == Decimal(b):
                return "numeric_format"
        except InvalidOperation:
            pass
    return None


class Result:
    def __init__(self):
        self.failures = []
        self.notes = {"numeric_format": [], "metadata": [], "disabled_param": [], "bd_param_echo": []}

    def fail(self, where, reference, candidate):
        self.failures.append({"where": where, "reference": reference, "candidate": candidate})

    def note(self, kind, where, reference, candidate):
        self.notes[kind].append({"where": where, "reference": reference, "candidate": candidate})

    def leaf(self, where, a, b):
        kind = equal_value(a, b)
        if kind is None:
            self.fail(where, a, b)
        elif kind == "numeric_format":
            self.note("numeric_format", where, a, b)


def compare_bd_component_parameters(res, where, a, b, xci_params):
    """BD parameter dicts; one-sided entries must echo the reference XCI value."""
    for key in sorted(set(a) | set(b)):
        if key in a and key in b:
            compare_tree(res, f"{where}/{key}", a[key], b[key])
            continue
        present = a.get(key, b.get(key))
        value = present.get("value") if isinstance(present, dict) else None
        reference = (xci_params or {}).get(key, [{}])[0].get("value")
        if value is not None and reference is not None and equal_value(value, reference):
            res.note("bd_param_echo", f"{where}/{key}", a.get(key, "<absent>"), b.get(key, "<absent>"))
        else:
            res.fail(f"{where}/{key}", a.get(key, "<absent>"), b.get(key, "<absent>"))


def compare_tree(res, where, a, b, xcis=None):
    """Strict recursive comparison with numeric-format equivalence on leaves."""
    if isinstance(a, dict) and isinstance(b, dict):
        bd_component = xcis is not None and "xci_name" in a and a.get("xci_name") == b.get("xci_name")
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                res.fail(f"{where}/{key}", a.get(key, "<absent>"), b.get(key, "<absent>"))
            elif bd_component and key == "parameters" and isinstance(a[key], dict) and isinstance(b[key], dict):
                xci = xcis.get(a["xci_name"], {}).get("ip_inst", {})
                params = xci.get("parameters", {}).get("component_parameters")
                compare_bd_component_parameters(res, f"{where}/{key}", a[key], b[key], params)
            else:
                compare_tree(res, f"{where}/{key}", a[key], b[key], xcis)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            res.fail(f"{where}[len]", len(a), len(b))
        for i, (x, y) in enumerate(zip(a, b)):
            compare_tree(res, f"{where}[{i}]", x, y, xcis)
    else:
        res.leaf(where, a, b)


def compare_parameter(res, where, a, b):
    """Parameter entries are one-element lists of field dicts."""
    if not (isinstance(a, list) and isinstance(b, list) and len(a) == len(b) == 1):
        compare_tree(res, where, a, b)
        return
    a, b = a[0], b[0]
    if (a.get("enabled") is False and b.get("enabled") is False
            and set(a) == set(b) and equal_value(a.get("value"), b.get("value")) is None):
        res.note("disabled_param", f"{where}.value", a.get("value"), b.get("value"))
        a = dict(a, value=b.get("value"))
    for field in GATED_FIELDS:
        if field in a or field in b:
            if field not in a or field not in b:
                res.fail(f"{where}.{field}", a.get(field, "<absent>"), b.get(field, "<absent>"))
            else:
                res.leaf(f"{where}.{field}", a[field], b[field])
    for field in sorted((set(a) | set(b)) - set(GATED_FIELDS)):
        if a.get(field, "<absent>") != b.get(field, "<absent>"):
            res.note("metadata", f"{where}.{field}", a.get(field, "<absent>"), b.get(field, "<absent>"))


def compare_parameter_group(res, where, a, b, skip=()):
    for name in sorted(set(a) | set(b)):
        if name in skip:
            continue
        if name not in a or name not in b:
            res.fail(f"{where}/{name}", "<present>" if name in a else "<absent>",
                     "<present>" if name in b else "<absent>")
        else:
            compare_parameter(res, f"{where}/{name}", a[name], b[name])


def compare_xci(res, name, a, b):
    a, b = a["ip_inst"], b["ip_inst"]
    for key in ("xci_name", "component_reference", "ip_revision"):
        res.leaf(f"{name}:{key}", a.get(key, "<absent>"), b.get(key, "<absent>"))
    if "cell_name" in a and "cell_name" in b:
        res.leaf(f"{name}:cell_name", a["cell_name"], b["cell_name"])
    elif "cell_name" in a or "cell_name" in b:
        res.note("metadata", f"{name}:cell_name", a.get("cell_name", "<absent>"), b.get("cell_name", "<absent>"))
    pa, pb = a.get("parameters", {}), b.get("parameters", {})
    for group in sorted(set(pa) | set(pb)):
        if group not in pa or group not in pb:
            res.fail(f"{name}:parameters/{group}", group in pa, group in pb)
            continue
        skip = LOCATION_RUNTIME if group == "runtime_parameters" else ()
        compare_parameter_group(res, f"{name}:{group}", pa[group], pb[group], skip)
    ba, bb = a.get("boundary", {}), b.get("boundary", {})
    compare_tree(res, f"{name}:boundary/ports", ba.get("ports", {}), bb.get("ports", {}))
    ia, ib = ba.get("interfaces", {}), bb.get("interfaces", {})
    for intf in sorted(set(ia) | set(ib)):
        if intf not in ia or intf not in ib:
            res.fail(f"{name}:interface/{intf}", intf in ia, intf in ib)
            continue
        x, y = ia[intf], ib[intf]
        for key in sorted((set(x) | set(y)) - {"parameters"}):
            compare_tree(res, f"{name}:interface/{intf}/{key}", x.get(key, "<absent>"), y.get(key, "<absent>"))
        compare_parameter_group(res, f"{name}:interface/{intf}/parameters",
                                x.get("parameters", {}), y.get("parameters", {}))


def bd_dir(project):
    found = sorted(Path(project).glob("*.srcs/sources_1/bd/system"))
    if len(found) != 1:
        raise FileNotFoundError(f"Expected one *.srcs/sources_1/bd/system under {project}")
    return found[0]


def load_xcis(root):
    xcis = {}
    for path in sorted((root / "ip").glob("*/*.xci")):
        xcis[path.stem] = json.loads(path.read_text(encoding="utf-8"))
    return xcis


def compare(reference, candidate):
    res = Result()
    ra, rb = bd_dir(reference), bd_dir(candidate)
    bda = json.loads((ra / "system.bd").read_text(encoding="utf-8"))
    bdb = json.loads((rb / "system.bd").read_text(encoding="utf-8"))
    xa, xb = load_xcis(ra), load_xcis(rb)
    if not xa:
        raise FileNotFoundError(f"No XCI under reference {ra}")
    compare_tree(res, "system.bd", bda, bdb, xa)
    for name in sorted(set(xa) | set(xb)):
        if name not in xa or name not in xb:
            res.fail(f"xci/{name}", "<present>" if name in xa else "<absent>",
                     "<present>" if name in xb else "<absent>")
        else:
            compare_xci(res, f"xci/{name}", xa[name], xb[name])
    return res, len(xa), len(xb)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--reference", required=True, help="accepted project directory")
    parser.add_argument("--candidate", required=True, help="project directory to check")
    parser.add_argument("--out", required=True, help="fresh JSON report path")
    args = parser.parse_args(argv)
    out = Path(args.out)
    if out.exists():
        raise FileExistsError("Use a fresh report path")
    res, na, nb = compare(args.reference, args.candidate)
    status = "PASS" if not res.failures else "FAIL"
    report = {
        "status": status,
        "reference": str(Path(args.reference).resolve()),
        "candidate": str(Path(args.candidate).resolve()),
        "xci_count": {"reference": na, "candidate": nb},
        "failure_count": len(res.failures),
        "note_counts": {k: len(v) for k, v in res.notes.items()},
        "failures": res.failures,
        "notes": res.notes,
    }
    out.write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"BD_STATE_{status} xci={na}/{nb} failures={len(res.failures)} "
          + " ".join(f"{k}={len(v)}" for k, v in res.notes.items()))
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())

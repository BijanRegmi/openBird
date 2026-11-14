"""Semantic diff of two Shorebird openapi.yaml files.

Usage: python3 -I tool/spec_diff.py <old.yaml> <new.yaml>

Prints operations added/removed/changed and, per schema, properties added,
removed, retyped, or newly required. Exit code 1 when anything differs.
"""
import json
import sys

import yaml


def load(path):
    return yaml.safe_load(open(path))


def operations(spec):
    ops = {}
    for path, item in spec.get("paths", {}).items():
        for method, op in item.items():
            if method in ("get", "post", "put", "patch", "delete"):
                ops[f"{method.upper()} {path}"] = op
    return ops


def strip(node):
    if isinstance(node, dict):
        return {k: strip(v) for k, v in node.items() if k not in ("description", "example", "examples", "summary")}
    if isinstance(node, list):
        return [strip(v) for v in node]
    return node


def main():
    old, new = load(sys.argv[1]), load(sys.argv[2])
    changed = False
    o_ops, n_ops = operations(old), operations(new)
    for key in sorted(n_ops.keys() - o_ops.keys()):
        print(f"+ operation {key} ({n_ops[key].get('operationId')})")
        changed = True
    for key in sorted(o_ops.keys() - n_ops.keys()):
        print(f"- operation {key} ({o_ops[key].get('operationId')})")
        changed = True
    for key in sorted(o_ops.keys() & n_ops.keys()):
        a, b = strip(o_ops[key]), strip(n_ops[key])
        if a != b:
            print(f"~ operation {key}")
            for part in sorted(set(a) | set(b)):
                if a.get(part) != b.get(part):
                    print(f"    {part}: {json.dumps(a.get(part))[:300]}")
                    print(f"     -> {json.dumps(b.get(part))[:300]}")
            changed = True

    o_s = old.get("components", {}).get("schemas", {})
    n_s = new.get("components", {}).get("schemas", {})
    for name in sorted(n_s.keys() - o_s.keys()):
        print(f"+ schema {name}")
        changed = True
    for name in sorted(o_s.keys() - n_s.keys()):
        print(f"- schema {name}")
        changed = True
    for name in sorted(o_s.keys() & n_s.keys()):
        a, b = strip(o_s[name]), strip(n_s[name])
        if a == b:
            continue
        changed = True
        print(f"~ schema {name}")
        ap, bp = a.get("properties") or {}, b.get("properties") or {}
        for p in sorted(bp.keys() - ap.keys()):
            print(f"    + {p}: {json.dumps(bp[p])}")
        for p in sorted(ap.keys() - bp.keys()):
            print(f"    - {p}")
        for p in sorted(ap.keys() & bp.keys()):
            if ap[p] != bp[p]:
                print(f"    ~ {p}: {json.dumps(ap[p])} -> {json.dumps(bp[p])}")
        ar, br = set(a.get("required") or []), set(b.get("required") or [])
        if ar != br:
            print(f"    required: +{sorted(br - ar)} -{sorted(ar - br)}")
        if a.get("enum") != b.get("enum"):
            print(f"    enum: {a.get('enum')} -> {b.get('enum')}")
    sys.exit(1 if changed else 0)


if __name__ == "__main__":
    main()

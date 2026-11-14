"""Extracts every (METHOD, path) the Shorebird code push client calls.

Usage: python3 -I tool/extract_client_routes.py <code_push_client.dart>

Paths are normalised to the openapi style, `$appId` -> `{appId}`, so they
can be compared with protocol/openapi.yaml.
"""
import re
import sys

src = open(sys.argv[1]).read()
routes = set()
# Each public method body: find the HTTP verb used and the `$_v1/...` URI.
# Split the class into member chunks at each two-space-indented member start.
chunks = re.split(r"\n  (?=(?:static |@|Future<|[A-Z]\w*(?:<[^>]*>)? \w+\())", src)
for body in chunks:
    uris = re.findall(r"'\$_v1/([^']*)'(?:\s*'([^']*)')?", body)
    if not uris:
        continue
    verb = None
    for v in ("get", "post", "put", "patch", "delete"):
        if re.search(rf"_httpClient\.{v}\(", body) or re.search(
            rf"(Request|MultipartRequest)\(\s*'{v.upper()}'", body
        ):
            verb = v.upper()
            break
    if verb is None and "_getEveryPage" in body:
        verb = "GET"
    if verb is None and "_getJson" in body:
        verb = "GET"
    for first, cont in uris:
        path = "/" + first + (cont or "")
        if "$path" in path or "$response" in path:
            continue  # generic helpers (shorebird api, invitation accept/decline)
        path = re.sub(r"\$\{Uri\.encodeComponent\((\w+)\)\}", r"{\1}", path)
        path = re.sub(r"\$\{(\w+)\}", r"{\1}", path)
        path = re.sub(r"\$(\w+)", r"{\1}", path).rstrip("/")
        routes.add((verb or "?", path))

for verb, path in sorted(routes, key=lambda r: (r[1], r[0])):
    print(f"{verb} {path}")

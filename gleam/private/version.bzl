"""Version-string comparison used to pick the highest of several toolchain version pins.

Extracted from gleam/extensions.bzl so it can be unit tested directly: module extension logic
itself isn't testable via analysistest (which only exercises rule() targets resolved during the
analysis phase), but a plain Starlark function like this one is -- see test/unit/version.
"""

visibility(["//gleam/...", "//test/..."])

def parse_version(version):
    """Parses a dotted version string into a list of ints for numeric comparison.

    Each dot-separated component is read only up to its first non-digit character, so a
    prerelease-style suffix like "0-rc1" parses as plain 0; an empty or all-non-digit
    component also parses as 0.

    Args:
      version: a dotted version string, e.g. "1.14.0" or "2.0.0-rc1".

    Returns:
      A list of ints, one per dot-separated component, suitable as a sort key.
    """
    parts = []
    for part in version.split("."):
        num = ""
        for i in range(len(part)):
            char = part[i]
            if char.isdigit():
                num += char
            else:
                break
        if num:
            parts.append(int(num))
        else:
            parts.append(0)
    return parts

def select_version(versions):
    """Picks the highest of several requested versions.

    Args:
      versions: version strings requested by different modules; may repeat.

    Returns:
      A struct with `selected` (the highest version) and `distinct` (the unique requested
      versions, highest first). More than one distinct version means modules disagree.
    """
    distinct = sorted({v: True for v in versions}.keys(), key = parse_version, reverse = True)
    return struct(selected = distinct[0], distinct = distinct)

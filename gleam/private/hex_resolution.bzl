"""Resolve shared Hex declarations before creating any repositories."""

visibility(["//gleam/...", "//test/..."])

def hex_declaration(name, version, sha256, deps, source, build_tools = [], otp_app = "", allow_plain_erlang = False, is_root = False, override = False):
    """Normalize a package declaration and retain its provenance.

    Args:
        name: Hex package name.
        version: Exact version.
        sha256: Outer archive checksum.
        deps: Required package names.
        source: Module and tag description for diagnostics.
        build_tools: Declared build tools.
        otp_app: OTP application name (defaults to name).
        allow_plain_erlang: Explicit plain Erlang audit opt-in.
        is_root: Whether the declaring module is the root.
        override: Whether the root explicitly replaces other declarations.

    Returns:
        A declaration with a normalized package and provenance.
    """
    return struct(
        package = struct(
            name = name,
            version = version,
            sha256 = sha256.lower(),
            deps = sorted({dep: True for dep in deps}),
            build_tools = sorted({tool: True for tool in build_tools}),
            otp_app = otp_app or name,
            allow_plain_erlang = allow_plain_erlang,
        ),
        source = source,
        is_root = is_root,
        override = override,
    )

def _describe(declaration):
    pkg = declaration.package
    return "{} (version {}, sha256 {})".format(declaration.source, pkg.version, pkg.sha256)

def resolve_hex_packages(declarations):
    """Deduplicate declarations, apply explicit root overrides and validate the graph.

    Args:
        declarations: Values returned by hex_declaration, in any module order.

    Returns:
        Normalized package structs, sorted by name. Invalid graphs fail before fetching.
    """
    by_name = {}
    overrides = {}
    checksums = {}
    for declaration in declarations:
        pkg = declaration.package
        by_name.setdefault(pkg.name, []).append(declaration)
        if declaration.override:
            if not declaration.is_root:
                fail("Only the root module may set override = True: {}".format(declaration.source))
            if pkg.name in overrides:
                fail("Multiple root overrides for Hex package '{}': {} and {}. Keep exactly one override.".format(
                    pkg.name,
                    overrides[pkg.name].source,
                    declaration.source,
                ))
            overrides[pkg.name] = declaration

        # A version identifies immutable bytes. Even a root override cannot bless
        # contradictory checksums for the same version (including unselected pins).
        key = (pkg.name, pkg.version)
        if key in checksums and checksums[key].package.sha256 != pkg.sha256:
            fail("Conflicting checksums for Hex package '{}' version {}: {} and {}. Verify the archive checksum and correct the declarations; override = True cannot change immutable package bytes.".format(
                pkg.name,
                pkg.version,
                _describe(checksums[key]),
                _describe(declaration),
            ))
        checksums[key] = declaration

    selected = {}
    for name in sorted(by_name):
        candidates = by_name[name]
        chosen = overrides.get(name, candidates[0])
        if name not in overrides:
            for candidate in candidates[1:]:
                differences = [
                    field
                    for field in ["version", "sha256", "deps", "build_tools", "otp_app", "allow_plain_erlang"]
                    if getattr(chosen.package, field) != getattr(candidate.package, field)
                ]
                if differences:
                    fail("Conflicting declarations for Hex package '{}': {} and {} differ in {}. Align the declarations, or select a complete package declaration with gleam.hex_package(..., override = True) in the root MODULE.bazel after checking compatibility.".format(
                        name,
                        _describe(chosen),
                        _describe(candidate),
                        ", ".join(differences),
                    ))
        selected[name] = chosen

    for name, declaration in selected.items():
        for dep in declaration.package.deps:
            if dep not in selected:
                fail("Hex package '{}' from {} requires undeclared package '{}'. Declare the full dependency graph with gleam.hex_package(...) or gleam.hex_manifest(...).".format(name, declaration.source, dep))

    # Remove leaves in rounds: Starlark disallows recursion and while loops.
    # At most one round per package is needed for any acyclic graph.
    pending = dict(selected)
    for _ in range(len(pending)):
        ready = [name for name, declaration in pending.items() if not any([dep in pending for dep in declaration.package.deps])]
        if not ready:
            fail("Dependency cycle in Hex packages; unresolved declarations: {}. Correct the requirements in these packages.".format(
                "; ".join(["{} from {} requires {}".format(name, declaration.source, declaration.package.deps) for name, declaration in pending.items()]),
            ))
        for name in ready:
            pending.pop(name)
        if not pending:
            break

    return [declaration.package for declaration in selected.values()]

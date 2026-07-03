"""Implementation of the gleam_test rule.

Uses `gleam compile-package --test` to compile both source and test files,
then runs the tests via `erl`, with a small shim that reuses gleeunit's own
test-discovery logic (see gleam_eunit_runner.erl) while adding JUnit/XML
output and `--test_filter` support that gleeunit's own zero-argument API
doesn't expose.
"""

load("//gleam/private:gleam_library.bzl", "GleamPackageInfo")

def _gleam_test_impl(ctx):
    if ctx.attr.shard_count > 1:
        fail((
            "gleam_test does not yet support shard_count > 1: each shard would " +
            "redundantly run the whole suite rather than a partition of it. " +
            "Remove the shard_count attribute from {}."
        ).format(ctx.label))

    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain

    package_name = ctx.attr.package_name

    # Declare compiled output directory.
    compiled_dir = ctx.actions.declare_directory("_gleam_test_pkg/" + package_name)

    # Collect dependency info.
    dep_infos = []
    transitive_dep_sets = []
    for dep in ctx.attr.deps:
        if GleamPackageInfo in dep:
            dep_info = dep[GleamPackageInfo]
            dep_infos.append(dep_info)
            transitive_dep_sets.append(dep_info.transitive_compiled_dirs)

    # All transitive dep dirs (flattened for inputs and -pa flags).
    all_dep_dirs = depset(transitive = transitive_dep_sets)

    # Prepare inputs.
    input_files = list(ctx.files.srcs) + list(ctx.files.test_srcs)
    if ctx.files.data:
        input_files.extend(ctx.files.data)
    inputs_depset = depset(
        direct = input_files,
        transitive = [all_dep_dirs],
    )

    # Determine src and test directories from file paths.
    src_dir = _get_dir(ctx.files.srcs, "src")

    # Build the compile command.
    cmd_parts = []

    # Sandbox-safe XDG dirs.
    cmd_parts.append("export XDG_CACHE_HOME=$(pwd)/.cache")
    cmd_parts.append("export XDG_DATA_HOME=$(pwd)/.local/share")

    # Set up --lib directory with symlinks to dep outputs.
    cmd_parts.append("mkdir -p _gleam_lib")
    for dep_info in dep_infos:
        cmd_parts.append('ln -s "$(pwd)/{compiled}" "_gleam_lib/{name}"'.format(
            compiled = dep_info.compiled_dir.path,
            name = dep_info.package_name,
        ))

    # Compile with --test flag to include test sources.
    compile_cmd = '"{wrapper}" "{tool}" compile-package --target=erlang --package="$(pwd)/{src}" --out="$(pwd)/{out}" --lib="$(pwd)/_gleam_lib"'.format(
        wrapper = gleam_exe_wrapper.path,
        tool = underlying_gleam_tool.path,
        src = src_dir,
        out = compiled_dir.path,
    )
    cmd_parts.append(compile_cmd)

    compile_command = " && ".join(cmd_parts)

    ctx.actions.run_shell(
        command = compile_command,
        tools = depset([gleam_exe_wrapper, underlying_gleam_tool]),
        inputs = inputs_depset,
        outputs = [compiled_dir],
        # See gleam_library.bzl's identical env setting for why: erlc (invoked internally by
        # `gleam compile-package`) otherwise embeds Bazel's per-action sandbox path into the
        # compiled output.
        env = {"ERL_COMPILER_OPTIONS": "[deterministic]"},
        progress_message = "Compiling Gleam tests: " + package_name,
        mnemonic = "GleamCompileTest",
    )

    # Compile the eunit runner shim to a .beam file.
    runner_src = ctx.file._gleam_eunit_runner
    runner_beam_dir = ctx.actions.declare_directory("_gleam_eunit_runner/" + ctx.label.name)

    erlc_path = erlang_toolchain.erlc_path_str
    if not erlc_path:
        erlc_path = "erlc"

    ctx.actions.run(
        executable = erlc_path,
        # See gleam_binary.bzl's identical +deterministic flag for why.
        arguments = ["+deterministic", "-o", runner_beam_dir.path, runner_src.path],
        inputs = [runner_src],
        outputs = [runner_beam_dir],
        mnemonic = "CompileGleamEunitRunner",
        progress_message = "Compiling Gleam eunit runner shim",
        use_default_shell_env = True,
    )

    # Create the test runner script that invokes erl.
    test_runner_script = ctx.actions.declare_file(ctx.label.name + "_test_runner.sh")

    erl_path = "erl"
    if hasattr(erlang_toolchain, "erl_path_str") and erlang_toolchain.erl_path_str:
        erl_path = erlang_toolchain.erl_path_str

    # Build -pa flags for compiled test output + all dep ebin dirs + the runner shim.
    # At test runtime, paths are relative to $TEST_SRCDIR/$WORKSPACE.
    ws_name = ctx.workspace_name
    compiled_runtime_path = "$TEST_SRCDIR/{ws}/{path}".format(
        ws = ws_name,
        path = compiled_dir.short_path,
    )
    runner_beam_runtime_path = "$TEST_SRCDIR/{ws}/{path}".format(
        ws = ws_name,
        path = runner_beam_dir.short_path,
    )

    pa_parts = [
        '-pa "{}/ebin"'.format(compiled_runtime_path),
        '-pa "{}"'.format(runner_beam_runtime_path),
    ]
    for dep_dir in all_dep_dirs.to_list():
        dep_runtime_path = "$TEST_SRCDIR/{ws}/{path}".format(
            ws = ws_name,
            path = dep_dir.short_path,
        )
        pa_parts.append('-pa "{}/ebin"'.format(dep_runtime_path))

    pa_flags = " ".join(pa_parts)

    # gleam_eunit_runner discovers which compiled modules to run as tests by scanning a
    # "test" directory *relative to the process's current working directory* at runtime
    # (it reuses gleeunit_ffi.erl's find_files/2, the same mechanism gleeunit:main/0 uses).
    # Bazel's test-setup.sh already chdirs into $TEST_SRCDIR/$TEST_WORKSPACE before running
    # this script, so for a package declared at the workspace root that's exactly where its
    # "test" directory's runfiles land. For a package nested under a subdirectory (e.g.
    # "outer/inner"), we must additionally cd into that subdirectory ourselves, or the runner
    # will silently find no "test" directory and discover zero test modules.
    script_lines = [
        "#!/bin/bash",
        "# Test runner for Gleam tests: " + ctx.label.name,
        "",
    ]
    if src_dir:
        script_lines.append('cd "{}"'.format(src_dir))
    script_lines.extend([
        "",
        # Bazel always sets XML_OUTPUT_FILE for `bazel test`; it's absent for `bazel run`.
        # eunit_surefire (part of OTP's eunit application) writes one TEST-<module>.xml
        # file per tested module into a directory, so it's pointed at a scratch dir and
        # the resulting files are merged into the single file Bazel expects below.
        'if [ -n "$XML_OUTPUT_FILE" ]; then',
        '  export GLEAM_EUNIT_XML_DIR="${TEST_TMPDIR:-/tmp}/gleam_eunit_xml"',
        '  mkdir -p "$GLEAM_EUNIT_XML_DIR"',
        "fi",
        # Bazel appends `args` (the attribute) and any --test_arg flags to this script's
        # own argv; expose them to test code that wants them via an env var, since passing
        # arbitrary strings through erl's `-s Mod Func Arg...` mechanism (which converts
        # each word to an atom) is lossy for anything but simple keyword-like arguments.
        'export GLEAM_TEST_ARGS="$*"',
        "",
        '"{erl}" {pa} -noshell -s gleam_eunit_runner main -s init stop'.format(
            erl = erl_path,
            pa = pa_flags,
        ),
        "EXIT_CODE=$?",
        "",
        'if [ -n "$XML_OUTPUT_FILE" ] && [ -d "$GLEAM_EUNIT_XML_DIR" ]; then',
        "  {",
        "    echo '<?xml version=\"1.0\" encoding=\"UTF-8\"?>'",
        "    echo '<testsuites>'",
        '    for f in "$GLEAM_EUNIT_XML_DIR"/TEST-*.xml; do',
        '      [ -e "$f" ] && tail -n +2 "$f"',
        "    done",
        "    echo '</testsuites>'",
        '  } > "$XML_OUTPUT_FILE"',
        "fi",
        "",
        "exit $EXIT_CODE",
    ])

    ctx.actions.write(
        output = test_runner_script,
        is_executable = True,
        content = "\n".join(script_lines) + "\n",
    )

    # Runfiles: test runner needs the compiled test dir, all dep dirs, the compiled eunit
    # runner shim, the raw test_srcs (so the runtime scan of "test/" actually finds
    # something to run -- see above), and any declared runtime data.
    runfiles_files = (
        [compiled_dir, runner_beam_dir] +
        all_dep_dirs.to_list() +
        list(ctx.files.test_srcs) +
        list(ctx.files.data)
    )

    return [
        DefaultInfo(
            executable = test_runner_script,
            runfiles = ctx.runfiles(files = runfiles_files),
        ),
    ]

def _get_dir(files, expected_component):
    """Derive a directory path from files by looking for an expected path component."""
    if not files:
        fail("No files provided for '{}' directory.".format(expected_component))

    first_file = files[0]
    path = first_file.path
    parts = path.split("/")
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == expected_component:
            if expected_component == "src":
                return "/".join(parts[:i])
            return "/".join(parts[:i + 1])

    # Fallback: directory of the first file.
    return first_file.dirname

gleam_test = rule(
    implementation = _gleam_test_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Source files (typically glob([\"src/**/*.gleam\", \"src/**/*.erl\", \"src/**/*.mjs\"])).",
            allow_files = [".gleam", ".erl", ".mjs"],
            mandatory = True,
        ),
        "test_srcs": attr.label_list(
            doc = "Test files (typically glob([\"test/**/*.gleam\", \"test/**/*.erl\", \"test/**/*.mjs\"])).",
            allow_files = [".gleam", ".erl", ".mjs"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Gleam package dependencies (including test deps like gleeunit).",
            providers = [GleamPackageInfo],
            default = [],
        ),
        "package_name": attr.string(
            doc = "The name of the Gleam package under test.",
            mandatory = True,
        ),
        "data": attr.label_list(
            doc = "Runtime data dependencies.",
            allow_files = True,
            default = [],
        ),
        "_gleam_eunit_runner": attr.label(
            default = Label("//gleam/private:gleam_eunit_runner.erl"),
            allow_single_file = True,
        ),
    },
    toolchains = ["//gleam:toolchain_type"],
    test = True,
    doc = """\
Compiles `srcs + test_srcs` together with `gleam compile-package --test`, then runs the
resulting tests via a small EUnit-based runner shim that reuses gleeunit's own test-module
discovery.

- `bazel test --test_output=errors` and JUnit/XML test result output (read by many CI
  systems) both work: a `TEST-XXX.xml` report is written per test module and merged into
  the single file Bazel's `$XML_OUTPUT_FILE` expects.
- `bazel test --test_filter=SUBSTRING` filters at test-*module* (i.e. test file) granularity,
  not individual `_test` function granularity.
- `args` (the attribute) and `--test_arg` are exposed to test code via the `GLEAM_TEST_ARGS`
  environment variable (space-joined), not via argv, since Erlang's `-s Mod Func Arg...`
  mechanism converts each word to an atom, which is lossy for arbitrary strings.
- `shard_count > 1` is rejected at analysis time rather than silently running the whole
  suite redundantly in every shard: sharding support is not implemented yet.
""",
)

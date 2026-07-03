"""A build-time check that a gleam_package's `package_name` agrees with its `gleam.toml`.

Uses Bazel's validation output group (see
https://bazel.build/extending/rules#validations_output_group) so the check runs whenever the
package is built or tested, without adding its output to the package's default outputs or
slowing down the critical path.
"""

visibility(["//gleam/...", "//test/..."])

def _gleam_package_name_check_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.run_shell(
        outputs = [marker],
        inputs = [ctx.file.gleam_toml],
        command = """
set -eu
if ! grep -Eq '^name[[:space:]]*=[[:space:]]*"{package_name}"[[:space:]]*$' "{toml}"; then
  echo "ERROR: {toml} does not declare name = \\"{package_name}\\"," >&2
  echo "but the Bazel target {label} declares package_name = \\"{package_name}\\"." >&2
  echo "Keep gleam.toml's 'name' field in sync with the Bazel package_name attribute." >&2
  exit 1
fi
touch "{marker}"
""".format(
            toml = ctx.file.gleam_toml.path,
            package_name = ctx.attr.package_name,
            label = str(ctx.label),
            marker = marker.path,
        ),
        mnemonic = "GleamPackageNameCheck",
        progress_message = "Checking package_name matches gleam.toml for %s" % ctx.label,
    )
    return [
        DefaultInfo(files = depset([marker])),
        OutputGroupInfo(_validation = depset([marker])),
    ]

gleam_package_name_check = rule(
    implementation = _gleam_package_name_check_impl,
    attrs = {
        "gleam_toml": attr.label(
            doc = "The gleam.toml file for this package.",
            allow_single_file = True,
            mandatory = True,
        ),
        "package_name": attr.string(
            doc = "The package_name that must match gleam.toml's `name` field.",
            mandatory = True,
        ),
    },
    doc = "Validates that a gleam.toml's `name` field matches a Bazel package_name attribute.",
)

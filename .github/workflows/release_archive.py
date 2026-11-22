"""Build the version-stamped source archive consumed by releases and BCR."""

import argparse
import gzip
import io
from pathlib import Path
import re
import subprocess
import tarfile


def release_names(tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", tag):
        raise ValueError(f"Expected a version tag such as v1.2.3 or v1.2.3-rc1, got {tag!r}")
    return tag[1:], f"rules_gleam-{tag[1:]}", f"rules_gleam-{tag}.tar.gz"


def stamp_module(content, version):
    stamped, count = re.subn(
        r'(module\(\s*name\s*=\s*"muchq_rules_gleam",\s*version\s*=\s*")[^"]+("\s*,)',
        lambda match: match[1] + version + match[2], content, count=1,
    )
    if count != 1:
        raise ValueError("Could not find the ruleset module version to stamp")
    return stamped


def build_archive(tag, ref, output_dir):
    version, prefix, filename = release_names(tag)
    source = subprocess.check_output(["git", "archive", "--format=tar", ref])
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / filename
    with tarfile.open(fileobj=io.BytesIO(source)) as original:
        members = original.getmembers()
        if not any(member.name == "examples/smoke/MODULE.bazel" for member in members):
            raise ValueError("Source archive must include the BCR smoke test module")
        with destination.open("wb") as output, gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for member in members:
                    data = original.extractfile(member) if member.isfile() else None
                    if member.name == "MODULE.bazel":
                        content = stamp_module(data.read().decode(), version).encode()
                        data = io.BytesIO(content)
                        member.size = len(content)
                    member.name = prefix + "/" + member.name
                    member.uid = member.gid = member.mtime = 0
                    member.uname = member.gname = ""
                    member.pax_headers = {}
                    archive.addfile(member, data)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("--ref", help="Source ref for CI snapshots; releases default to the exact tag")
    parser.add_argument("--output-dir", type=Path, default=Path.cwd())
    args = parser.parse_args()
    print(build_archive(args.tag, args.ref or "refs/tags/" + args.tag, args.output_dir))


if __name__ == "__main__":
    main()

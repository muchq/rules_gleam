# Bazel rules for Gleam

> [!WARNING]
> THESE RULES ARE EXPERIMENTAL AND ARE PROBABLY BROKEN BECAUSE THERE ARE ONLY VERY BASIC E2E TESTS! YOU HAVE BEEN WARNED!

> [!CAUTION]
> DID I MENTION THAT I MOSTLY VIBE-CODED THEM OVER A WEEKEND? YOU HAVE BEEN WARNED AGAIN!

> [!WARNING]
> THESE RULES ARE NOT HERMETIC BECAUSE I DON'T KNOW HOW TO BUILD ERLANG FROM SOURCE AND I'M WORRIED THAT rabbitmq/rules_erlang IS NOT SUPPORTED BECAUSE OTHER RABBITMQ PROJECTS HAVE MOVED AWAY FROM BAZEL! THEY REQUIRE A WORKING ERLANG INSTALLATION AVAILABLE ON YOUR PATH! THIS IS YOUR THIRD AND FINAL WARNING!

## Installation

Add the following to your `MODULE.bazel` file:

```starlark
bazel_dep(name = "muchq_rules_gleam", version = "0.0.1")
git_override(
    module_name = "muchq_rules_gleam",
    remote = "https://github.com/muchq/rules_gleam.git",
    tag = "v0.1.0",
)
```

## Usage

See a basic example [here](e2e/smoke)

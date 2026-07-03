// Package gleam implements a Gazelle language extension for Gleam projects.
//
// For any directory containing a gleam.toml and at least one src/**/*.gleam
// file, it generates a single gleam_package(...) macro call: srcs/test_srcs
// as glob() expressions, deps/test_deps derived from gleam.toml's
// [dependencies]/[dev-dependencies] keys (mapped to @gleam_packages//:<name>,
// the label convention gleam.hex_package(...)/gleam.hex_manifest(...)
// register targets under), and entry_module = "main" when src/main.gleam
// is present.
//
// This only manages BUILD files: Hex dependency declarations themselves
// (MODULE.bazel's gleam.hex_package/hex_manifest tags) are out of scope --
// see gleam/extensions.bzl.
package gleam

import (
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

const gleamPackageKind = "gleam_package"

type gleamLang struct {
	language.BaseLang
}

// NewLanguage returns a new instance of the Gleam Gazelle language extension.
func NewLanguage() language.Language {
	return &gleamLang{}
}

func (*gleamLang) Name() string { return "gleam" }

func (*gleamLang) Kinds() map[string]rule.KindInfo {
	return map[string]rule.KindInfo{
		gleamPackageKind: {
			NonEmptyAttrs: map[string]bool{"srcs": true},
			MergeableAttrs: map[string]bool{
				"srcs":      true,
				"test_srcs": true,
				"deps":      true,
				"test_deps": true,
				"data":      true,
				"test_data": true,
			},
		},
	}
}

func (*gleamLang) Loads() []rule.LoadInfo {
	return []rule.LoadInfo{
		{
			Name:    "@rules_gleam//gleam:defs.bzl",
			Symbols: []string{gleamPackageKind},
		},
	}
}

func (*gleamLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	var result language.GenerateResult

	pkg, ok := readGleamPackage(args.Dir)
	if !ok {
		return result
	}

	r := rule.NewRule(gleamPackageKind, pkg.name)
	r.SetAttr("srcs", rule.GlobValue{Patterns: []string{"src/**/*.gleam"}})
	r.SetAttr("gleam_toml", "gleam.toml")
	if len(pkg.deps) > 0 {
		r.SetAttr("deps", pkg.deps)
	}
	if pkg.hasTests {
		r.SetAttr("test_srcs", rule.GlobValue{Patterns: []string{"test/**/*.gleam"}})
		if len(pkg.testDeps) > 0 {
			r.SetAttr("test_deps", pkg.testDeps)
		}
	}
	if pkg.hasMain {
		r.SetAttr("entry_module", "main")
	}

	result.Gen = []*rule.Rule{r}
	result.Imports = []interface{}{nil}
	return result
}

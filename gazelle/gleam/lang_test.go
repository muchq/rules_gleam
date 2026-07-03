package gleam

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

func generateAndFormat(t *testing.T, dir, rel string) (string, bool) {
	t.Helper()
	l := NewLanguage()
	result := l.GenerateRules(language.GenerateArgs{Dir: dir, Rel: rel})
	if len(result.Gen) == 0 {
		return "", false
	}
	if len(result.Gen) != len(result.Imports) {
		t.Fatalf("len(Gen) = %d != len(Imports) = %d", len(result.Gen), len(result.Imports))
	}

	f := rule.EmptyFile(filepath.Join(dir, "BUILD.bazel"), rel)
	for _, r := range result.Gen {
		r.Insert(f)
	}
	f.Sync()
	return string(f.Format()), true
}

func TestGenerateRules_LibraryWithTests(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "gleam.toml"), `
name = "my_app"
version = "0.1.0"

[dependencies]
gleam_stdlib = "~> 0.60"

[dev-dependencies]
gleeunit = "~> 1.0"
`)
	writeFile(t, filepath.Join(dir, "src", "my_app.gleam"), `pub fn greeting() { "hi" }`)
	writeFile(t, filepath.Join(dir, "test", "my_app_test.gleam"), `pub fn main() {}`)

	got, ok := generateAndFormat(t, dir, "")
	if !ok {
		t.Fatalf("expected a rule to be generated")
	}
	t.Logf("generated BUILD file:\n%s", got)

	for _, want := range []string{
		`gleam_package(`,
		`name = "my_app"`,
		`srcs = glob(["src/**/*.gleam"])`,
		`gleam_toml = "gleam.toml"`,
		`deps = ["@gleam_packages//:gleam_stdlib"]`,
		`test_srcs = glob(["test/**/*.gleam"])`,
		`test_deps = ["@gleam_packages//:gleeunit"]`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("generated BUILD file missing %q\ngot:\n%s", want, got)
		}
	}
	if strings.Contains(got, "entry_module") {
		t.Errorf("did not expect entry_module for a library-only package\ngot:\n%s", got)
	}
}

func TestGenerateRules_Binary(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "gleam.toml"), `name = "my_app"`+"\n"+`version = "0.1.0"`+"\n")
	writeFile(t, filepath.Join(dir, "src", "my_app.gleam"), `pub fn greeting() { "hi" }`)
	writeFile(t, filepath.Join(dir, "src", "main.gleam"), `pub fn main() { greeting() }`)

	got, ok := generateAndFormat(t, dir, "")
	if !ok {
		t.Fatalf("expected a rule to be generated")
	}
	t.Logf("generated BUILD file:\n%s", got)

	if !strings.Contains(got, `entry_module = "main"`) {
		t.Errorf("expected entry_module = \"main\"\ngot:\n%s", got)
	}
}

func TestGenerateRules_NoGleamToml(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "src", "my_app.gleam"), `pub fn greeting() { "hi" }`)

	if _, ok := generateAndFormat(t, dir, ""); ok {
		t.Errorf("expected no rule to be generated without a gleam.toml")
	}
}

func TestKindsAndLoads(t *testing.T) {
	l := NewLanguage()
	kinds := l.Kinds()
	if _, ok := kinds[gleamPackageKind]; !ok {
		t.Errorf("Kinds() missing %q", gleamPackageKind)
	}

	loads := l.Loads()
	if len(loads) != 1 || loads[0].Name != "@rules_gleam//gleam:defs.bzl" {
		t.Errorf("Loads() = %+v, want a single load from @rules_gleam//gleam:defs.bzl", loads)
	}
	found := false
	for _, s := range loads[0].Symbols {
		if s == gleamPackageKind {
			found = true
		}
	}
	if !found {
		t.Errorf("Loads()[0].Symbols = %v, want it to contain %q", loads[0].Symbols, gleamPackageKind)
	}
}

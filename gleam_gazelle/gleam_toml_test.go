package gleam

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestReadGleamPackage_LibraryWithTests(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "gleam.toml"), `
name = "my_app"
version = "0.1.0"

[dependencies]
gleam_stdlib = "~> 0.60"
gleam_http = ">= 4.0.0 and < 5.0.0"

[dev-dependencies]
gleeunit = "~> 1.0"
`)
	writeFile(t, filepath.Join(dir, "src", "my_app.gleam"), `pub fn greeting() { "hi" }`)
	writeFile(t, filepath.Join(dir, "test", "my_app_test.gleam"), `pub fn main() {}`)

	pkg, ok := readGleamPackage(dir)
	if !ok {
		t.Fatalf("expected ok = true")
	}
	if pkg.name != "my_app" {
		t.Errorf("name = %q, want my_app", pkg.name)
	}
	wantDeps := []string{"@gleam_packages//:gleam_http", "@gleam_packages//:gleam_stdlib"}
	if !reflect.DeepEqual(pkg.deps, wantDeps) {
		t.Errorf("deps = %v, want %v", pkg.deps, wantDeps)
	}
	wantTestDeps := []string{"@gleam_packages//:gleeunit"}
	if !reflect.DeepEqual(pkg.testDeps, wantTestDeps) {
		t.Errorf("testDeps = %v, want %v", pkg.testDeps, wantTestDeps)
	}
	if !pkg.hasTests {
		t.Errorf("hasTests = false, want true")
	}
	if pkg.hasMain {
		t.Errorf("hasMain = true, want false")
	}
}

func TestReadGleamPackage_BinaryNoTests(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "gleam.toml"), `
name = "my_app"
version = "0.1.0"

[dependencies]
gleam_stdlib = "~> 0.60"
`)
	writeFile(t, filepath.Join(dir, "src", "my_app.gleam"), `pub fn greeting() { "hi" }`)
	writeFile(t, filepath.Join(dir, "src", "main.gleam"), `pub fn main() { greeting() }`)

	pkg, ok := readGleamPackage(dir)
	if !ok {
		t.Fatalf("expected ok = true")
	}
	if !pkg.hasMain {
		t.Errorf("hasMain = false, want true")
	}
	if pkg.hasTests {
		t.Errorf("hasTests = true, want false")
	}
}

func TestReadGleamPackage_NoGleamToml(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "src", "my_app.gleam"), `pub fn greeting() { "hi" }`)

	if _, ok := readGleamPackage(dir); ok {
		t.Errorf("expected ok = false when gleam.toml is absent")
	}
}

func TestReadGleamPackage_NoSources(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "gleam.toml"), `name = "my_app"`+"\n"+`version = "0.1.0"`+"\n")

	if _, ok := readGleamPackage(dir); ok {
		t.Errorf("expected ok = false when there are no src/**/*.gleam files")
	}
}

func TestReadGleamPackage_NoDeps(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "gleam.toml"), `name = "my_app"`+"\n"+`version = "0.1.0"`+"\n")
	writeFile(t, filepath.Join(dir, "src", "my_app.gleam"), `pub fn greeting() { "hi" }`)

	pkg, ok := readGleamPackage(dir)
	if !ok {
		t.Fatalf("expected ok = true")
	}
	if len(pkg.deps) != 0 {
		t.Errorf("deps = %v, want empty", pkg.deps)
	}
}

func TestReadGleamPackage_NestedSrcs(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "gleam.toml"), `name = "my_app"`+"\n"+`version = "0.1.0"`+"\n")
	writeFile(t, filepath.Join(dir, "src", "sub", "deep.gleam"), `pub fn f() { 1 }`)

	pkg, ok := readGleamPackage(dir)
	if !ok {
		t.Fatalf("expected ok = true for a nested src/**/*.gleam file")
	}
	if pkg.name != "my_app" {
		t.Errorf("name = %q, want my_app", pkg.name)
	}
}

func TestReadGleamPackage_NameFieldNeverMatchedInsideDependenciesSection(t *testing.T) {
	// A pathological gleam.toml where a dependency happens to be declared before the
	// root "name" field would be malformed TOML (name must be in the root table,
	// which always precedes any [section]), but guard against ever reading a
	// same-named key from inside a later section regardless.
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "gleam.toml"), `
name = "real_name"
version = "0.1.0"

[dependencies]
name = "should_not_be_used"
`)
	writeFile(t, filepath.Join(dir, "src", "my_app.gleam"), `pub fn f() { 1 }`)

	pkg, ok := readGleamPackage(dir)
	if !ok {
		t.Fatalf("expected ok = true")
	}
	if pkg.name != "real_name" {
		t.Errorf("name = %q, want real_name", pkg.name)
	}
}

func TestSectionKeys(t *testing.T) {
	content := `
name = "x"

[dependencies]
gleam_stdlib = "~> 0.60"
# a comment
mist = ">= 6.0.0"

[dev-dependencies]
gleeunit = "~> 1.0"
`
	got := sectionKeys(content, "dependencies")
	want := []string{"gleam_stdlib", "mist"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("sectionKeys(dependencies) = %v, want %v", got, want)
	}

	got = sectionKeys(content, "dev-dependencies")
	want = []string{"gleeunit"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("sectionKeys(dev-dependencies) = %v, want %v", got, want)
	}

	got = sectionKeys(content, "nonexistent")
	if len(got) != 0 {
		t.Errorf("sectionKeys(nonexistent) = %v, want empty", got)
	}
}

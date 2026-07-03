package gleam

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// gleamPackage describes a single Gleam package (one gleam.toml) discovered
// on disk, translated into the inputs needed to generate a gleam_package(...)
// rule.
type gleamPackage struct {
	name     string
	deps     []string
	testDeps []string
	hasTests bool
	hasMain  bool
}

var packageNameRe = regexp.MustCompile(`(?m)^\s*name\s*=\s*"([^"]+)"`)

// readGleamPackage inspects dir for a gleam.toml with at least one
// src/**/*.gleam file. It returns ok = false if dir isn't a Gleam package
// root Gazelle should generate a target for.
func readGleamPackage(dir string) (gleamPackage, bool) {
	data, err := os.ReadFile(filepath.Join(dir, "gleam.toml"))
	if err != nil {
		return gleamPackage{}, false
	}
	content := string(data)

	// Only look at the root table (before the first [section] header), so a
	// dependency that happened to be named "name" can never be confused for
	// the package's own name field.
	rootTable := content
	if i := sectionHeaderRe.FindStringIndex(content); i != nil {
		rootTable = content[:i[0]]
	}
	m := packageNameRe.FindStringSubmatch(rootTable)
	if m == nil {
		return gleamPackage{}, false
	}

	if !hasGleamSources(filepath.Join(dir, "src")) {
		return gleamPackage{}, false
	}

	return gleamPackage{
		name:     m[1],
		deps:     hexDepLabels(sectionKeys(content, "dependencies")),
		testDeps: hexDepLabels(sectionKeys(content, "dev-dependencies")),
		hasTests: hasGleamSources(filepath.Join(dir, "test")),
		hasMain:  fileExists(filepath.Join(dir, "src", "main.gleam")),
	}, true
}

// hexDepLabels maps Hex package names to @gleam_packages//:<name> labels,
// matching the naming convention gleam.hex_package(...)/gleam.hex_manifest(...)
// register their generated gleam_library targets under.
func hexDepLabels(names []string) []string {
	labels := make([]string, 0, len(names))
	for _, n := range names {
		labels = append(labels, "@gleam_packages//:"+n)
	}
	return labels
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// hasGleamSources reports whether dir contains at least one *.gleam file,
// at any depth. A missing dir is treated as having no sources.
func hasGleamSources(dir string) bool {
	found := false
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || found {
			return nil
		}
		if !d.IsDir() && strings.HasSuffix(path, ".gleam") {
			found = true
		}
		return nil
	})
	return found
}

var (
	sectionHeaderRe = regexp.MustCompile(`(?m)^\[([^\]]+)\]\s*$`)
	tomlKeyRe       = regexp.MustCompile(`(?m)^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*=`)
)

// sectionKeys returns the sorted keys declared directly under a top-level
// TOML table, e.g. sectionKeys(content, "dependencies") for keys under
// "[dependencies]". Nested/inline tables and arrays of tables aren't
// supported: gleam.toml's [dependencies]/[dev-dependencies] never use them.
func sectionKeys(content string, section string) []string {
	var keys []string
	inSection := false
	for _, line := range strings.Split(content, "\n") {
		if m := sectionHeaderRe.FindStringSubmatch(line); m != nil {
			inSection = strings.TrimSpace(m[1]) == section
			continue
		}
		if !inSection {
			continue
		}
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if m := tomlKeyRe.FindStringSubmatch(line); m != nil {
			keys = append(keys, m[1])
		}
	}
	sort.Strings(keys)
	return keys
}

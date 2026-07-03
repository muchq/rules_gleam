package gleam

import (
	"flag"
	"os"
	"path/filepath"
	"testing"
)

var updateGolden = flag.Bool("update", false, "regenerate testdata/golden/*/BUILD.want files from current output")

// TestGolden runs the Gleam Gazelle language extension against every fixture directory under
// testdata/golden and compares its generated output to a checked-in BUILD.want file -- the same
// testdata-driven convention bazel-gazelle's own language extensions use for regression tests,
// rather than the inline string assertions the rest of this package's tests use.
//
// This calls GenerateRules directly, the same way lang_test.go's other tests do, which does not
// merge in the load(...) statement Loads() declares -- that's the outer gazelle CLI's own
// resolver's job, exercised for real (compiled gazelle_binary, actual load statement included)
// against testdata/sample_package by a CI step, not by this test.
//
// A fixture directory with no BUILD.want is expected to generate no rule at all (e.g. a missing
// or malformed gleam.toml). Run `go test ./gleam_gazelle/... -run TestGolden -update` to
// regenerate BUILD.want files after an intentional output change.
func TestGolden(t *testing.T) {
	entries, err := os.ReadDir("testdata/golden")
	if err != nil {
		t.Fatalf("reading testdata/golden: %v", err)
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := entry.Name()
		t.Run(name, func(t *testing.T) {
			dir := filepath.Join("testdata/golden", name)
			wantPath := filepath.Join(dir, "BUILD.want")

			got, ok := generateAndFormat(t, dir, "")

			if *updateGolden {
				if !ok {
					return // no rule generated: leave BUILD.want absent
				}
				if err := os.WriteFile(wantPath, []byte(got), 0o644); err != nil {
					t.Fatalf("writing %s: %v", wantPath, err)
				}
				return
			}

			_, statErr := os.Stat(wantPath)
			wantsRule := statErr == nil

			if !wantsRule {
				if ok {
					t.Errorf("expected no rule to be generated, but got:\n%s", got)
				}
				return
			}
			if !ok {
				t.Fatalf("expected a rule to be generated, but none was")
			}

			want, err := os.ReadFile(wantPath)
			if err != nil {
				t.Fatalf("reading %s: %v", wantPath, err)
			}
			if string(want) != got {
				t.Errorf(
					"generated BUILD file does not match %s (run with -update to regenerate)\ngot:\n%s\nwant:\n%s",
					wantPath, got, string(want),
				)
			}
		})
	}
}

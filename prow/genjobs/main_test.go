/*
Copyright 2019 Istio Authors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"bytes"
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/pflag"

	"istio.io/test-infra/prow/genjobs/cmd/genjobs"
)

const (
	testDir = "testdata"
)

func resolvePath(t *testing.T, filename string) string {
	name := strings.ToLower(filepath.Base(t.Name()))
	return filepath.Join(testDir, strings.ToLower(name), name+filename)
}

func TestGenjobs(t *testing.T) {
	tests := []struct {
		name   string
		output string
		args   []string
		equal  bool
	}{
		{
			name:  "simple transform",
			args:  []string{"--mapping=istio=istio-private"},
			equal: true,
		},
		{
			name:  "branches-out",
			args:  []string{"--mapping=istio=istio-private", "--branches-out=custom-1,^custom-2$"},
			equal: true,
		},
		{
			name:  "extra-refs exists",
			args:  []string{"--mapping=istio=istio-private", "--extra-refs"},
			equal: true,
		},
		{
			name:  "extra-refs not exists",
			args:  []string{"--mapping=istio=istio-private", "--extra-refs"},
			equal: true,
		},
		{
			name:  "rerun-orgs",
			args:  []string{"--mapping=istio=istio-private", "--rerun-orgs=istio-private,istio-secret"},
			equal: true,
		},
		{
			name:  "rerun-users",
			args:  []string{"--mapping=istio=istio-private", "--rerun-users=clarketm,scoobydoo"},
			equal: true,
		},
		{
			name:  "override annotations",
			args:  []string{"--mapping=istio=istio-private", "--annotations=testgrid-create-test-group=false"},
			equal: true,
		},
		{
			name:  "sort ascending",
			args:  []string{"--mapping=istio=istio-private", "--sort=asc"},
			equal: true,
		},
		{
			name:  "sort descending",
			args:  []string{"--mapping=istio=istio-private", "--sort=desc"},
			equal: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			in := resolvePath(t, "_in.yaml")
			outE := resolvePath(t, "_out.yaml")

			expected, err := ioutil.ReadFile(outE)
			if err != nil {
				t.Errorf("Failed reading expected output file %v: %v", outE, err)
			}

			tmpDir, err := ioutil.TempDir("", "")
			if err != nil {
				t.Errorf("Failed creating temp file: %v", err)
			}
			defer os.Remove(tmpDir)

			outA := filepath.Join(tmpDir, "out.yaml")

			os.Args = []string{"genjobs"}
			pflag.CommandLine = pflag.NewFlagSet(os.Args[0], pflag.ExitOnError)
			os.Args = append(os.Args, test.args...)
			os.Args = append(os.Args, "--input="+in, "--output="+outA)
			genjobs.Main()

			actual, err := ioutil.ReadFile(outA)
			if err != nil {
				t.Errorf("Failed reading actual output file %v: %v", outA, err)
			}

			if os.Getenv("VERBOSE") == "true" {
				fmt.Printf("expected (%v):\n%v\n", test.name, string(expected))
				fmt.Printf("actual (%v):\n%v\n", test.name, string(actual))
			}

			if os.Getenv("REFRESH_GOLDEN") == "true" {
				if err = ioutil.WriteFile(outE, actual, 0644); err != nil {
					t.Errorf("Failed writing expected output file %v: %v", outE, err)
				}
				expected = actual
			}

			equal := bytes.Equal(expected, actual)
			if equal != test.equal {
				t.Errorf("Expected output to be: %t.\nAdd env variable VERBOSE=true for details", test.equal)
			}
		})
	}
}

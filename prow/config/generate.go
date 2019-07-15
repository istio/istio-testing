package main

import (
	"errors"
	"fmt"
	"github.com/ghodss/yaml"
	"github.com/hashicorp/go-multierror"
	"github.com/kr/pretty"
	"io/ioutil"
	"k8s.io/api/core/v1"
	"k8s.io/test-infra/prow/config"
	"os"
	"path"
	"strings"
)

func exit(err error, context string) {
	if context == "" {
		_, _ = fmt.Fprint(os.Stderr, fmt.Sprintf("%v", err))
	} else {
		_, _ = fmt.Fprint(os.Stderr, fmt.Sprintf("%v: %v", context, err))
	}
	os.Exit(1)
}

func printConfig(c interface{}) {
	bytes, err := yaml.Marshal(c)
	if err != nil {
		exit(err, "failed to write result")
	}
	fmt.Println(string(bytes))
}

const (
	DefaultResource = "default"

	ModifierHidden   = "hidden"
	ModifierOptional = "optional"
	ModifierSkipped  = "skipped"

	TypePostsubmit = "postsubmit"
	TypePresubmit  = "presubmit"

	RequirementRoot   = "root"
	RequirementKind   = "kind"
	RequirementBoskos = "boskos"
)

type JobConfig struct {
	Jobs      []Job                              `json:"jobs"`
	Repo      string                             `json:"repo"`
	Branches  []string                           `json:"branches"`
	Resources map[string]v1.ResourceRequirements `json:"resources"`
}

type Job struct {
	Name           string   `json:"name"`
	PostsubmitName string   `json:"postsubmit"`
	Command        []string `json:"command"`
	Resources      string   `json:"resources"`
	Modifiers      []string `json:"modifiers"`
	Requirements   []string `json:"requirements"`
	Type           string   `json:"type"`
}

func main() {
	if len(os.Args) != 2 {
		exit(errors.New("must provide one of write, diff, check, print"), "")
	}
	jobs := readJobConfig("jobs/istio.yaml")
	for _, branch := range jobs.Branches {
		validateConfig(jobs)
		presubmit, postsubmit := convertJobConfig(jobs.Jobs, branch, jobs.Resources)
		output := config.JobConfig{
			Presubmits:  map[string][]config.Presubmit{jobs.Repo: presubmit},
			Postsubmits: map[string][]config.Postsubmit{jobs.Repo: postsubmit},
		}

		switch os.Args[1] {
		case "write":
			writeConfig(output, jobs.Repo, branch)
		case "diff":
			fmt.Println("Presubmit diff:")
			diffConfigPresubmit(output)
			fmt.Println("\n\nPostsubmit diff:")
			diffConfigPostsubmit(output)
		case "check":
			//panic("not implemented")
		case "print":
			fallthrough
		default:
			printConfig(output)
		}
	}
}

func writeConfig(jobs config.JobConfig, fqRepo string, branch string) {
	outdir := "out"
	if err := os.MkdirAll(outdir, 0755); err != nil {
		exit(err, "failed to create output dir")
	}

	r := strings.Split(fqRepo, "/")
	org, repo := r[0], r[1]
	key := fmt.Sprintf("%s.%s.%s.yaml", org, repo, branch)

	outfile := path.Join(outdir, key)
	bytes, err := yaml.Marshal(jobs)
	if err != nil {
		exit(err, "failed to marshal result")
	}
	output := []byte("# THIS FILE IS AUTOGENERATED. See generate.go and jobs/.\n")
	output = append(output, bytes...)
	err = ioutil.WriteFile(outfile, output, 0755)
	if err != nil {
		exit(err, "failed to write result")
	}
}

func validate(input string, options []string, description string) error {
	valid := false
	for _, opt := range options {
		if input == opt {
			valid = true
		}
	}
	if !valid {
		return fmt.Errorf("'%v' is not a valid %v. Must be one of %v", input, description, strings.Join(options, ", "))
	}
	return nil
}

func validateConfig(jobConfig JobConfig) {
	var err error
	if _, f := jobConfig.Resources[DefaultResource]; !f {
		err = multierror.Append(err, fmt.Errorf("'%v' resource must be provided", DefaultResource))
	}
	for _, job := range jobConfig.Jobs {
		if job.Resources != "" {
			if _, f := jobConfig.Resources[job.Resources]; !f {
				err = multierror.Append(err, fmt.Errorf("job '%v' has nonexistant resource '%v'", job.Name, job.Resources))
			}
		}
		for _, mod := range job.Modifiers {
			if e := validate(mod, []string{ModifierHidden, ModifierOptional, ModifierSkipped}, "status"); e != nil {
				err = multierror.Append(err, e)
			}
		}
		for _, req := range job.Requirements {
			if e := validate(req, []string{RequirementKind, RequirementRoot, RequirementBoskos}, "requirements"); e != nil {
				err = multierror.Append(err, e)
			}
		}
		if e := validate(job.Type, []string{TypePostsubmit, TypePresubmit, ""}, "type"); e != nil {
			err = multierror.Append(err, e)
		}
	}
	if err != nil {
		exit(err, "validation failed")
	}
}

func diffConfigPresubmit(result config.JobConfig) {
	pj := readProwJobConfig("../cluster/jobs/istio/istio/istio.istio.master.yaml")
	known := make(map[string]struct{})
	for _, job := range result.AllPresubmits([]string{"istio/istio"}) {
		known[job.Name] = struct{}{}
		current := pj.GetPresubmit("istio/istio", job.Name)
		if current == nil {
			fmt.Println("\nCreated unknown presubmit job", job.Name)
			continue
		}
		current.Context = ""
		diff := pretty.Diff(current, &job)
		if len(diff) > 0 {
			fmt.Println("\nDiff for", job.Name)
		}
		for _, d := range diff {
			fmt.Println(d)
		}
	}
	for _, job := range pj.AllPresubmits([]string{"istio/istio"}) {
		if _, f := known[job.Name]; !f {
			fmt.Println("Missing", job.Name)
		}
	}
}

func diffConfigPostsubmit(result config.JobConfig) {
	pj := readProwJobConfig("../cluster/jobs/istio/istio/istio.istio.master.yaml")
	known := make(map[string]struct{})
	allCurrentPostsubmits := pj.AllPostsubmits([]string{"istio/istio"})
	for _, job := range result.AllPostsubmits([]string{"istio/istio"}) {
		known[job.Name] = struct{}{}
		var current *config.Postsubmit
		for _, ps := range allCurrentPostsubmits {
			if ps.Name == job.Name {
				current = &ps
				break
			}
		}
		if current == nil {
			fmt.Println("\nCreated unknown job:", job.Name)
			continue

		}
		diff := pretty.Diff(current, &job)
		if len(diff) > 0 {
			fmt.Println("\nDiff for", job.Name)
		}
		for _, d := range diff {
			fmt.Println(d)
		}
	}

	for _, job := range pj.AllPostsubmits([]string{"istio/istio"}) {
		if _, f := known[job.Name]; !f {
			fmt.Println("Missing", job.Name)
		}
	}

}

func createContainer(job Job, resources map[string]v1.ResourceRequirements) []v1.Container {
	c := v1.Container{
		Image:           "gcr.io/istio-testing/istio-builder:v20190709-959ee177",
		SecurityContext: &v1.SecurityContext{Privileged: newTrue()},
		Command:         job.Command,
	}
	resource := DefaultResource
	if job.Resources != "" {
		resource = job.Resources
	}
	c.Resources = resources[resource]

	return []v1.Container{c}
}

func convertJobConfig(jobs []Job, branch string, resources map[string]v1.ResourceRequirements) ([]config.Presubmit, []config.Postsubmit) {
	presubmits := []config.Presubmit{}
	postsubmits := []config.Postsubmit{}

	for _, job := range jobs {
		brancher := config.Brancher{
			Branches: []string{fmt.Sprintf("^%s$", branch)},
		}
		if job.Type == TypePresubmit || job.Type == "" {
			job.Command = append([]string{"entrypoint"}, job.Command...)
			presubmit := config.Presubmit{
				JobBase:   createJobBase(job, fmt.Sprintf("%s-%s", job.Name, branch), resources),
				AlwaysRun: true,
				Brancher:  brancher,
			}
			applyModifiersPresubmit(&presubmit, job.Modifiers)
			applyRequirementsPresubmit(&presubmit, job.Requirements)
			presubmits = append(presubmits, presubmit)
		}

		if job.Type == TypePostsubmit || job.Type == "" {
			postName := job.PostsubmitName
			if postName == "" {
				postName = job.Name
			}
			postsubmit := config.Postsubmit{
				JobBase:  createJobBase(job, fmt.Sprintf("%s-%s", postName, branch), resources),
				Brancher: brancher,
			}
			applyModifiersPostsubmit(&postsubmit, job.Modifiers)
			applyRequirementsPostsubmit(&postsubmit, job.Requirements)
			postsubmits = append(postsubmits, postsubmit)
		}
	}
	return presubmits, postsubmits
}

func createJobBase(job Job, name string, resources map[string]v1.ResourceRequirements) config.JobBase {
	return config.JobBase{
		Name: name,
		Spec: &v1.PodSpec{
			NodeSelector: map[string]string{"testing": "test-pool"},
			Containers:   createContainer(job, resources),
		},
		UtilityConfig: config.UtilityConfig{
			Decorate:  true,
			PathAlias: "istio.io/istio",
		},
		Labels: make(map[string]string),
	}
}

func applyRequirementsPresubmit(presubmit *config.Presubmit, requirements []string) {
	for _, req := range requirements {
		switch req {
		case RequirementBoskos:
			presubmit.MaxConcurrency = 5
			presubmit.Labels["preset-service-account"] = "true"
		case RequirementRoot:
			presubmit.JobBase.Spec.Containers[0].SecurityContext.Privileged = newTrue()
		case RequirementKind:
			dir := v1.HostPathDirectory
			presubmit.JobBase.Spec.Volumes = append(presubmit.JobBase.Spec.Volumes,
				v1.Volume{
					Name: "modules",
					VolumeSource: v1.VolumeSource{
						HostPath: &v1.HostPathVolumeSource{
							Path: "/lib/modules",
							Type: &dir,
						},
					},
				},
				v1.Volume{
					Name: "cgroup",
					VolumeSource: v1.VolumeSource{
						HostPath: &v1.HostPathVolumeSource{
							Path: "/sys/fs/cgroup",
							Type: &dir,
						},
					},
				},
			)
			presubmit.JobBase.Spec.Containers[0].VolumeMounts = append(presubmit.JobBase.Spec.Containers[0].VolumeMounts,
				v1.VolumeMount{
					MountPath: "/lib/modules",
					Name:      "modules",
					ReadOnly:  true,
				},
				v1.VolumeMount{
					MountPath: "/sys/fs/cgroup",
					Name:      "cgroup",
				},
			)
		}
	}
}

func applyModifiersPresubmit(presubmit *config.Presubmit, jobModifiers []string) {
	for _, modifier := range jobModifiers {
		if modifier == ModifierOptional {
			presubmit.Optional = true
		} else if modifier == ModifierHidden {
			presubmit.SkipReport = true
		} else if modifier == ModifierSkipped {
			presubmit.AlwaysRun = false
		}
	}
}

func applyRequirementsPostsubmit(postsubmit *config.Postsubmit, Requirements []string) {

}

func applyModifiersPostsubmit(postsubmit *config.Postsubmit, jobModifiers []string) {
	//for _, modifier := range jobModifiers {
	//	if modifier == ModifierOptional {
	//		postsubmit.Optional = true
	//	} else if modifier == ModifierHidden {
	//		postsubmit.SkipReport = true
	//	} else if modifier == ModifierSkipped {
	//		postsubmit.AlwaysRun = false
	//	}
	//}
}


func readProwJobConfig(file string) config.JobConfig {
	yamlFile, err := ioutil.ReadFile(file)
	if err != nil {
		exit(err, "failed to read "+file)
	}
	jobs := config.JobConfig{}
	if err := yaml.Unmarshal(yamlFile, &jobs); err != nil {
		exit(err, "failed to unmarshal "+file)
	}
	return jobs
}

func readJobConfig(file string) JobConfig {
	yamlFile, err := ioutil.ReadFile(file)
	if err != nil {
		exit(err, "failed to read "+file)
	}
	jobs := JobConfig{}
	if err := yaml.Unmarshal(yamlFile, &jobs); err != nil {
		exit(err, "failed to unmarshal "+file)
	}
	return jobs
}

func newTrue() *bool {
	b := true
	return &b
}

// Copyright 2017 Istio Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"strings"

	"istio.io/test-infra/toolbox/util"
)

var (
	repo       = flag.String("repo", "", "Update dependencies of only this repository")
	owner      = flag.String("owner", "istio", "Github Owner or org")
	tokenFile  = flag.String("token_file", "", "File containing Github API Access Token")
	baseBranch = flag.String("base_branch", "master", "Branch from which the deps update commit is based")
	githubClnt *githubClient
)

const (
	istioDepsFile = "istio.deps"
)

// Update the commit SHA reference in a given line from dependency file
// to the latest stable version
// Returns the updated line
func replaceCommit(line string, dep dependency) string {
	idx := strings.Index(line, "\"")
	return line[:idx] + "\"" + dep.LastStableSHA + "\","
}

// Generates an MD5 digest of the version set of the repo dependencies
// useful in avoiding making duplicate branches of the same code change
// Also updates dependency objects deserialized from istio.deps
func fingerPrintAndUpdateDepSHA(repo string, deps *[]dependency) (string, error) {
	digest, err := githubClnt.getHeadCommitSHA(repo, *baseBranch)
	if err != nil {
		return "", err
	}
	digest += *baseBranch
	for i, dep := range *deps {
		commitSHA, err := githubClnt.getHeadCommitSHA(dep.RepoName, dep.ProdBranch)
		if err != nil {
			return "", err
		}
		digest += commitSHA
		(*deps)[i].LastStableSHA = commitSHA
	}
	return util.GetMD5Hash(digest), nil
}

// Read the exported environment variable named :key in istio.VERSION
// and return its value
func istioVersionGet(key string) (string, error) {
	// exec always forks a child process to execute the given command, which means
	// istio.VERSION is sourced to a forked bash process and all exported values
	// are gone once the child process exits.
	// The following is a workaround to pass value back to the parent process,
	// which is whoever executing this go script
	cmd := fmt.Sprintf("source istio.VERSION ; echo $%s", key)
	value, err := exec.Command("bash", "-c", cmd).CombinedOutput()
	return strings.TrimSpace(string(value)), err
}

// Update the commit SHA reference in the dependency file of dep
func updateDepFile(dep dependency) error {
	input, err := ioutil.ReadFile(dep.File)
	if err != nil {
		return err
	}
	lines := strings.Split(string(input), "\n")
	for i, line := range lines {
		if strings.Contains(line, dep.Name+" = ") {
			lines[i] = replaceCommit(line, dep)
		}
	}
	output := strings.Join(lines, "\n")
	return ioutil.WriteFile(dep.File, []byte(output), 0600)
}

// Assumes at the root of istio directory
// Runs the updateVersion.sh script
func updateIstioDeps(deps *[]dependency) error {
	getSHAByName := func(name string) string {
		for _, d := range *deps {
			if d.RepoName == name {
				return d.LastStableSHA
			}
		}
		return ""
	}
	pilotSHA := getSHAByName("pilot")
	mixerSHA := getSHAByName("mixer")
	AuthSHA := getSHAByName("auth")
	if pilotSHA == "" || mixerSHA == "" || AuthSHA == "" {
		return fmt.Errorf("incomplete dependencies in %s", istioDepsFile)
	}
	caHub, err := istioVersionGet("CA_HUB")
	if err != nil {
		return err
	}
	phub, err := istioVersionGet("PILOT_HUB")
	if err != nil {
		return err
	}
	mhub, err := istioVersionGet("MIXER_HUB")
	if err != nil {
		return err
	}
	istioctlURL, err := istioVersionGet("ISTIOCTL_URL")
	if err != nil {
		return err
	}
	oldPilotSHA, err := istioVersionGet("PILOT_TAG")
	if err != nil {
		return err
	}
	istioctlURL = strings.Replace(istioctlURL, oldPilotSHA, pilotSHA, 1)
	cmd := fmt.Sprintf("./install/updateVersion.sh -p %s,%s -x %s,%s -i %s -c %s,%s",
		phub, pilotSHA, mhub, mixerSHA, istioctlURL, caHub, AuthSHA)
	_, err = util.Shell(cmd)
	return err
}

// Update the commit SHA reference in the dependency file of dep
func updateDeps(repo string, deps *[]dependency) error {
	if repo == "istio" {
		if err := updateIstioDeps(deps); err != nil {
			return err
		}
	} else {
		for _, dep := range *deps {
			if err := updateDepFile(dep); err != nil {
				return err
			}
		}
	}
	return nil
}

// Delete the local git repo just cloned
func cleanUp(repo string) error {
	if err := os.Chdir(".."); err != nil {
		return err
	}
	return os.RemoveAll(repo)
}

// Update the given repository so that it uses the latest dependency references
// push new branch to remote, create pull request on master,
// which is auto-merged after presumbit
func updateDependenciesOf(repo string) error {
	log.Printf("Updating dependencies of %s\n", repo)
	if err := os.RemoveAll(repo); err != nil {
		return err
	}
	if _, err := util.ShellSilent("git clone " + githubClnt.remote(repo)); err != nil {
		return err
	}
	if err := os.Chdir(repo); err != nil {
		return err
	}
	defer func() {
		if err := cleanUp(repo); err != nil {
			log.Fatalf("Error during clean up: %v\n", err)
		}
	}()
	if _, err := util.Shell("git checkout " + *baseBranch); err != nil {
		return err
	}
	deps, err := deserializeDeps(istioDepsFile)
	if err != nil {
		return err
	}
	depVersions, err := fingerPrintAndUpdateDepSHA(repo, &deps)
	if err != nil {
		return err
	}
	branch := "autoUpdateDeps_" + depVersions
	exists, err := githubClnt.existBranch(repo, branch)
	if err != nil {
		return err
	}
	if exists {
		log.Printf("Branch already exists")
	}
	// if branch exists, stop here and do not create another PR of identical delta
	if err = githubClnt.closeFailedPullRequests(repo, *baseBranch); exists || err != nil {
		return err
	}
	if _, err := util.Shell("git checkout -b " + branch); err != nil {
		return err
	}
	if err := updateDeps(repo, &deps); err != nil {
		return err
	}
	if err := serializeDeps(istioDepsFile, &deps); err != nil {
		return err
	}
	if _, err := util.Shell("git commit -am Update_Dependencies"); err != nil {
		return err
	}
	if _, err := util.Shell("git push --set-upstream origin " + branch); err != nil {
		return err
	}
	if err := githubClnt.createPullRequest(branch, *baseBranch, repo); err != nil {
		return err
	}
	return nil
}

func main() {
	flag.Parse()
	if *tokenFile == "" {
		log.Panicf("token_file not provided\n")
		return
	}
	token, err := util.GetAPITokenFromFile(*tokenFile)
	if err != nil {
		log.Panicf("Error accessing user supplied token_file: %v\n", err)
	}
	githubClnt, err = newGithubClient(*owner, token)
	if err != nil {
		log.Panicf("Error when initializing github client: %v\n", err)
	}
	if *repo != "" { // only update dependencies of this repo
		if err := updateDependenciesOf(*repo); err != nil {
			log.Printf("Failed to udpate dependency: %v\n", err)
		}
	} else { // update dependencies of all repos in the istio project
		repos, err := githubClnt.listRepos()
		if err != nil {
			log.Printf("Error when fetching list of repos: %v\n", err)
			return
		}
		for _, r := range repos {
			if err := updateDependenciesOf(r); err != nil {
				log.Printf("Failed to udpate dependency: %v\n", err)
			}
		}
	}
}

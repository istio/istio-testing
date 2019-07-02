/*
Copyright 2019 The Kubernetes Authors.

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

package bugzilla

import (
	"errors"
	"fmt"
	"net/http"

	"k8s.io/apimachinery/pkg/util/sets"
)

// Fake is a fake Bugzilla client with injectable fields
type Fake struct {
	EndpointString string
	Bugs           map[int]Bug
	BugErrors      sets.Int
	ExternalBugs   map[int][]ExternalBug
}

// Endpoint returns the endpoint for this fake
func (c *Fake) Endpoint() string {
	return c.EndpointString
}

// GetBug retrieves the bug, if registered, or an error, if set,
// or responds with an error that matches IsNotFound
func (c *Fake) GetBug(id int) (*Bug, error) {
	if c.BugErrors.Has(id) {
		return nil, errors.New("injected error getting bug")
	}
	if bug, exists := c.Bugs[id]; exists {
		return &bug, nil
	} else {
		return nil, &requestError{statusCode: http.StatusNotFound, message: "bug not registered in the fake"}
	}
}

// UpdateBug updates the bug, if registered, or an error, if set,
// or responds with an error that matches IsNotFound
func (c *Fake) UpdateBug(id int, update BugUpdate) error {
	if c.BugErrors.Has(id) {
		return errors.New("injected error updating bug")
	}
	if bug, exists := c.Bugs[id]; exists {
		bug.Status = update.Status
		c.Bugs[id] = bug
		return nil
	} else {
		return &requestError{statusCode: http.StatusNotFound, message: "bug not registered in the fake"}
	}
}

// AddPullRequestAsExternalBug adds an external bug to the Bugzilla bug,
// if registered, or an error, if set, or responds with an error that
// matches IsNotFound
func (c *Fake) AddPullRequestAsExternalBug(id int, org, repo string, num int) error {
	if c.BugErrors.Has(id) {
		return errors.New("injected error adding external bug to bug")
	}
	if _, exists := c.Bugs[id]; exists {
		c.ExternalBugs[id] = append(c.ExternalBugs[id], ExternalBug{
			TrackerID:     0, // impl detail of each bz server
			BugzillaBugID: id,
			ExternalBugID: fmt.Sprintf("%s/%s/pull/%d", org, repo, num),
		})
		return nil
	} else {
		return &requestError{statusCode: http.StatusNotFound, message: "bug not registered in the fake"}
	}
}

// the Fake is a Client
var _ Client = &Fake{}

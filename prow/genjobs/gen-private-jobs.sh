#!/usr/bin/env bash

# Copyright Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

COMMON_OPTS=(
  "--mapping=istio=istio-private"
  "--ssh-clone"
  "--extra-refs"
  "--input=./cluster/jobs/"
  "--output=./cluster/jobs/"
  "--bucket=istio-private-build"
  "--cluster=private"
  "--modifier=priv"
)

# Clean ./prow/cluster/jobs/istio-private directory
go run ./genjobs --clean --mapping=istio=istio-private --output=./cluster/jobs/ --dry-run

# istio/istio build job(s) - postsubmit(s)
go run ./genjobs \
  "${COMMON_OPTS[@]}" \
  --branches=release-1.4,master \
  --env DOCKER_HUB=gcr.io/istio-prow-build,GCS_BUCKET=istio-private-build/dev \
  --labels preset-enable-ssh=true \
  --job-type postsubmit \
  --repo-whitelist istio \
  --job-whitelist release_istio_postsubmit,release_istio_release-1.4_postsubmit

# istio/istio test jobs(s) - presubmit(s) and postsubmit(s)
go run ./genjobs \
  "${COMMON_OPTS[@]}" \
  --branches=release-1.4,master \
  --job-type presubmit,postsubmit \
  --repo-whitelist istio \
  --job-blacklist release_istio_postsubmit,release_istio_release-1.4_postsubmit

# istio/proxy master test jobs(s) - presubmit(s)
go run ./genjobs \
  "${COMMON_OPTS[@]}" \
  --branches master \
  --modifier=master_priv \
  --labels preset-enable-netrc=true \
  --job-type presubmit \
  --env BAZEL_ENVOY_PATH=/home/prow/go/src/istio.io/proxy/bazel-bin/src/envoy/envoy,BAZEL_BUILD_RBE_JOBS=0,ENVOY_REPOSITORY=https://github.com/envoyproxy/envoy-wasm,ENVOY_PREFIX=envoy-wasm \
  --repo-whitelist proxy

# istio/proxy master build jobs(s) - postsubmit(s)
go run ./genjobs \
  "${COMMON_OPTS[@]}" \
  --branches master \
  --modifier=master_priv \
  --labels preset-enable-netrc=true \
  --job-type postsubmit \
  --env BAZEL_BUILD_RBE_JOBS=0,GCS_BUILD_BUCKET=istio-private-build,GCS_ARTIFACTS_BUCKET=istio-private-artifacts,DOCKER_REPOSITORY=istio-prow-build/envoy,ENVOY_REPOSITORY=https://github.com/envoyproxy/envoy-wasm,ENVOY_PREFIX=envoy-wasm \
  --repo-whitelist proxy

# istio/proxy release-1.4 test jobs(s) - presubmit(s)
go run ./genjobs \
  "${COMMON_OPTS[@]}" \
  --branches release-1.4 \
  --modifier=release-1.4_priv \
  --labels preset-enable-netrc=true \
  --job-type presubmit \
  --env BAZEL_ENVOY_PATH=/home/prow/go/src/istio.io/proxy/bazel-bin/src/envoy/envoy,BAZEL_BUILD_RBE_JOBS=0,ENVOY_REPOSITORY=https://github.com/istio-private/envoy,ENVOY_PREFIX=envoy \
  --repo-whitelist proxy

# istio/proxy release-1.4 build jobs(s) - postsubmit(s)
go run ./genjobs \
  "${COMMON_OPTS[@]}" \
  --branches release-1.4 \
  --modifier=release-1.4_priv \
  --labels preset-enable-netrc=true \
  --job-type postsubmit \
  --env BAZEL_BUILD_RBE_JOBS=0,GCS_BUILD_BUCKET=istio-private-build,GCS_ARTIFACTS_BUCKET=istio-private-artifacts,DOCKER_REPOSITORY=istio-prow-build/envoy,ENVOY_REPOSITORY=https://github.com/istio-private/envoy,ENVOY_PREFIX=envoy \
  --repo-whitelist proxy

# istio/release-builder build jobs(s) - postsubmit(s)
go run ./genjobs \
  "${COMMON_OPTS[@]}" \
  --labels preset-override-envoy=true \
  --job-type postsubmit \
  --repo-whitelist release-builder

# istio/release-builder test jobs(s) - presubmit(s)
go run ./genjobs \
  "${COMMON_OPTS[@]}" \
  --job-type presubmit \
  --repo-whitelist release-builder

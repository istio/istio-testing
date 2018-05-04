#!/bin/bash

# Copyright 2017 Istio Authors

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.


#######################################################
# Crontab dependency update script triggered by Prow. #
#######################################################

# Exit immediately for non zero status
set -e
# Check unset variables
set -u
# Print commands
set -x

echo "=== Building Binary that Updates Istio Dependency ==="
bazel build //toolbox/deps_update:deps_update
UPDATE_BINARY="./bazel-bin/toolbox/deps_update/linux_amd64_stripped/deps_update"

git config --global user.email "istio.testing@gmail.com"
git config --global user.name "istio-bot"

TOKEN_PATH="/etc/github/oauth"


function update_on_branch {
   local CUR_BRANCH=$1
   local hour24=`date "+%k"` #(0..23)
   local day_of_week=`date "+%u"` #(1..7)

   case ${CUR_BRANCH} in
     #master|release-*)
     master)
       # for now skip master updates
       repos=( )
           ;;
     release-*)
       case ${hour24} in
         12|22)
           # List of repo where auto dependency update has been enabled excluding istio/istio
           repos=( proxy )
	   ${UPDATE_BINARY} \
	   	--repo="istio" \
	   	--base_branch=${CUR_BRANCH} \
		--token_file=${TOKEN_PATH} \
		--update_ext_dep="false"
           ;;
         *)
           ;;
       esac
       ;;
     *)
       echo error CUR_BRANCH:$CUR_BRANCH, all branches:$GIT_BRANCHES set incorrectly; exit 1
       ;;
   esac

   if [ "${hour24}" -ge 20 ] && [ "${day_of_week}" -eq 2 ]; then
       # external deps (envoyproxy in proxy) updated only once a week
        UPDATE_EXT_DEP="true"
   else
        UPDATE_EXT_DEP="false"
   fi


   for r in "${repos[@]}"; do
     echo "=== Updating Dependency of ${r} ==="
     ${UPDATE_BINARY} \
       --repo=${r} \
       --base_branch=${CUR_BRANCH} \
       --token_file=${TOKEN_PATH} \
       --update_ext_dep=${UPDATE_EXT_DEP}
   done
}


IFS=,
branches=($GIT_BRANCHES)
unset IFS

for branch in "${branches[@]}"; do
    update_on_branch $branch
done


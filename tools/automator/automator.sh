#!/usr/bin/env bash
# shellcheck disable=SC2016

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

set -euo pipefail

ROOT="$(cd -P "$(dirname -- "$0")" && pwd -P)"

# shellcheck disable=SC1090
source "$ROOT/utils.sh"

cleanup() {
  rm -rf "${tmp_dir:-}" "${tmp_token:-}" "${tmp_script:-}" "${tmp_git:-}"
}

get_opts() {
  if opt="$(getopt -o '' -l branch:,org:,repo:,title:,match-title:,body:,labels:,user:,email:,modifier:,script-path:,cmd:,token-path:,token:,merge-repository:,merge-branch:,git-exclude:,strict,dry-run,verbose -n "$(basename "$0")" -- "$@")"; then
    eval set -- "$opt"
  else
    print_error_and_exit "unable to parse options"
  fi

  while true; do
    case "$1" in
    --branch)
      branch="$2"
      shift 2
      ;;
    --org)
      org="$2"
      shift 2
      ;;
    --repo)
      repos="$(split_on_commas "$2")"
      shift 2
      ;;
    --title)
      title_tmpl="$2"
      shift 2
      ;;
    --match-title)
      match_title_tmpl="$2"
      shift 2
      ;;
    --body)
      body_tmpl="$2"
      shift 2
      ;;
    --labels)
      labels="$(echo "$2" | jq --raw-input --compact-output 'split(",")')"
      shift 2
      ;;
    --user)
      user="$2"
      shift 2
      ;;
    --email)
      email="$2"
      shift 2
      ;;
    --modifier)
      modifier="$2"
      shift 2
      ;;
    --script-path)
      script_path="$(realpath "$2")"
      shift 2
      ;;
    --cmd)
      tmp_script="$(mktemp -t script-XXXXXXXXXX)"
      echo "$2" >"$tmp_script"
      script_path="$tmp_script"
      shift 2
      ;;
    --token-path)
      token_path="$2"
      token="$(cat "$token_path")"
      shift 2
      ;;
    --token)
      token="$2"
      tmp_token="$(mktemp -t token-XXXXXXXXXX)"
      echo "$token" >"$tmp_token"
      token_path="$tmp_token"
      shift 2
      ;;
    --merge-repository)
      merge_repository="$2"
      shift 2
      ;;
    --merge-branch)
      merge_branch="$2"
      shift 2
      ;;
    --verbose)
      shell_args+=("-x")
      shift
      ;;
    --strict)
      strict=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --git-exclude)
      git_exclude="$2"
      shift 2
      ;;
    --)
      shift
      script_args=("$@")
      break
      ;;
    *)
      print_error_and_exit "unknown option: $1"
      ;;
    esac
  done
}

validate_opts() {
  sha="$(current_sha)"
  sha_short="$(current_sha --short)"
  commit_date="$(commit_date)"
  merge=false

  if [ -z "${strict:-}" ]; then
    strict=false
  fi

  if [ -z "${dry_run:-}" ]; then
    dry_run=false
  fi

  if [ -z "${branch:-}" ]; then
    branch="$(current_branch)"
  fi

  if [ -n "${merge_repository:-}" ] && [ -n "${merge_branch:-}" ]; then
    merge=true
  fi

  if [ -z "${title_tmpl:-}" ]; then
    title_tmpl='Automator: update $AUTOMATOR_ORG/$AUTOMATOR_REPO@$AUTOMATOR_BRANCH-$AUTOMATOR_MODIFIER'
  fi

  if [ -z "${match_title_tmpl:-}" ]; then
    match_title_tmpl="$title_tmpl"
  fi

  if [ -z "${body_tmpl:-}" ]; then
    body_tmpl='Generated by Automator - $(date -uIseconds)'
  fi

  if [ -z "${org:-}" ]; then
    print_error_and_exit "org is a required option"
  fi

  if [ -z "${repos:-}" ]; then
    print_error_and_exit "repo is a required option"
  fi

  if [ ! -f "${token_path:-}" ] || [ -z "${token:-}" ] && ! $dry_run; then
    print_error_and_exit "token_path or token is a required option"
  fi

  if [ ! -f "${script_path:-}" ] && ! $merge; then
    print_error_and_exit "either script-path, cmd, or merge-repository and merge-branch are required"
  fi

  if [ -z "${modifier:-}" ]; then
    modifier="automator"
  fi

  if [ -z "${user:-}" ] && ! $dry_run; then
    user="$(curl -sSfLH "Authorization: token $token" "https://api.github.com/user" | jq --raw-output ".login")"
  fi

  if [ -z "${email:-}" ] && ! $dry_run; then
    email="$(curl -sSfLH "Authorization: token $token" "https://api.github.com/user" | jq --raw-output ".email")"
  fi

  if [ -z "${git_exclude:-}" ]; then
    git_exclude=""
  fi
}

evaluate_opts() {
  AUTOMATOR_SRC_ORG="${REPO_OWNER:-}" AUTOMATOR_SRC_REPO="${REPO_NAME:-}" AUTOMATOR_SRC_BRANCH="${PULL_BASE_REF:-}"
  AUTOMATOR_SHA="$sha" AUTOMATOR_SHA_SHORT="$sha_short"
  AUTOMATOR_SHA_COMMIT_DATE="$commit_date"
  AUTOMATOR_ORG="$org" AUTOMATOR_REPO="$repo" AUTOMATOR_BRANCH="$branch" AUTOMATOR_MODIFIER="$modifier"

  title="$(evaluate_tmpl "$title_tmpl")"
  match_title="$(evaluate_tmpl "$match_title_tmpl")"
  body="$(evaluate_tmpl "$body_tmpl")"
}

export_globals() {
  export AUTOMATOR_SRC_ORG AUTOMATOR_SRC_REPO AUTOMATOR_SRC_BRANCH AUTOMATOR_SHA AUTOMATOR_SHA_SHORT AUTOMATOR_SHA_COMMIT_DATE \
    AUTOMATOR_ORG AUTOMATOR_REPO AUTOMATOR_BRANCH AUTOMATOR_MODIFIER AUTOMATOR_ROOT_DIR AUTOMATOR_REPO_DIR
}

create_pr() {
  pr-creator \
    --github-token-path="$token_path" \
    --org="$org" \
    --repo="$repo" \
    --branch="$branch" \
    --title="$title" \
    --match-title="\"$match_title\"" \
    --body="$body" \
    --source="$user:$fork_name" \
    --confirm
}

add_labels() {
  if [ "${labels:-}" ]; then
    curl -XPOST -sSfLH "Authorization: token $token" "https://api.github.com/repos/$org/$repo/issues/$pull_request/labels" --data "{\"labels\": $labels}" >/dev/null
  fi
}

commit() {
  if $dry_run; then
    git diff --cached
    return 0
  fi

  local src_branch="${AUTOMATOR_SRC_BRANCH:-none}"
  fork_name="$src_branch-$branch-$modifier-$(hash "$title")"
  git -c "user.name=$user" -c "user.email=$email" commit --message "$title" --author="$user <$email>"
  git show --shortstat
  git push --force "https://$user:$token@github.com/$user/$repo.git" "HEAD:$fork_name"
  pull_request="$(create_pr)"
  add_labels
}

merge() {
  local src_branch="${AUTOMATOR_SRC_BRANCH:-none}"
  fork_name="$src_branch-$branch-$modifier-$(hash "$title")"
  git remote add -f -t "$merge_branch" upstream "$merge_repository"
  set +e # git return a non-zero exit code on merge failure, which fails the script
  git -c "user.name=$user" -c "user.email=$email" merge --no-ff -m "$title" --log upstream/"$merge_branch"
  local code=$?
  set -e
  if [ "$code" -ne 0 ]; then
    export GITHUB_TOKEN="$token"
    local issue_exists
    issue_exists=$(gh issue list -S "Automatic merge of $merge_branch into $branch failed." -R "istio/istio" | wc -l)
    if [ "$issue_exists" -eq 0 ]; then
      gh issue create -b "Automatic merge of $merge_branch into $branch failed. @istio/wg-networking-maintainers" -t "Automatic merge of upstream envoy release branch failed" -l "area/networking/envoy" -R "istio/istio"
      print_error "Conflicts detected, manual merge is required. An issue in istio/istio has been created." 0
    else
      print_error "Conflicts detected, manual merge is required. An issue in istio/istio already exists." 0
    fi
  else
    if [[ "$(git show --shortstat)" =~ $title ]]; then
      git show --shortstat
      git push --force "https://$user:$token@github.com/$user/$repo.git" "HEAD:$fork_name"
      pull_request="$(create_pr)"
      add_labels
    else
      print_error "No changes to merge" 0
    fi
  fi
}

# validate_changes_exist_in_latest_commit validates changes exist in the prior commit after removing files specified
# in the git_exclude list. If no files remain after exclusion, the automation script exits.
validate_changes_exist_in_latest_commit() {
  if [ -n "$git_exclude" ]; then
    changes=$(git show --name-only --pretty=oneline | sed 1d | grep -cvE "$git_exclude") # need to remove first line
    if [ "${changes}" -eq 0 ]
    then
      print_error_and_exit "No changes remaining in upstream PR after excluding" 0  # not really an error so return 0
    fi
  fi
}

work() { (
  set -e

  evaluate_opts

  if ! $dry_run; then
    curl -XPOST -sSfLH "Authorization: token $token" "https://api.github.com/repos/$org/$repo/forks" >/dev/null
  fi

  # Some jobs expect GOPATH setup, so simulate this
  mkdir -p src/istio.io/"$repo"
  git clone --single-branch --branch "$branch" "https://github.com/$org/$repo.git" src/istio.io/"$repo"

  gopath=${PWD}
  pushd src/istio.io/"$repo"

  AUTOMATOR_REPO_DIR="$(pwd)"

  if $merge; then
    merge
  else
    GOPATH="${gopath}" bash "${shell_args[@]}" "$script_path" "${script_args[@]}"

    git add --all

    if ! git diff --cached --quiet --exit-code; then
      commit
    elif $strict; then
      print_error "no diff for $repo" 1
    fi
  fi

  popd
); }

main() {
  trap cleanup EXIT

  tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)

  get_opts "$@"
  validate_opts
  export_globals
  validate_changes_exist_in_latest_commit

  AUTOMATOR_ROOT_DIR="$(pwd)"

  pushd "$tmp_dir" || print_error_and_exit "invalid dir: $tmp_dir"

  set +e
  for repo in $repos; do
    work
    local code="$?"
    [ "$code" -ne 0 ] && exit_code="$code"
  done
  set -e

  popd || print_error_and_exit "invalid dir: $tmp_dir"
}

main "$@"
exit "${exit_code:-0}"

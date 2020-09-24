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
  if opt="$(getopt -o '' -l branch:,org:,repo:,title:,match-title:,body:,labels:,user:,email:,modifier:,script-path:,cmd:,token-path:,token:,strict,dry-run,verbose -n "$(basename "$0")" -- "$@")"; then
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

  if [ -z "${strict:-}" ]; then
    strict=false
  fi

  if [ -z "${dry_run:-}" ]; then
    dry_run=false
  fi

  if [ -z "${branch:-}" ]; then
    branch="$(current_branch)"
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

  if [ ! -f "${script_path:-}" ]; then
    print_error_and_exit "script-path or cmd is a required option"
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

work() { (
  set -e

  evaluate_opts

  if ! $dry_run; then
    curl -XPOST -sSfLH "Authorization: token $token" "https://api.github.com/repos/$org/$repo/forks" >/dev/null
  fi

  git clone --single-branch --branch "$branch" "https://github.com/$org/$repo.git" "$repo"

  pushd "$repo"

  AUTOMATOR_REPO_DIR="$(pwd)"

  bash "${shell_args[@]}" "$script_path" "${script_args[@]}"

  git add --all

  if ! git diff --cached --quiet --exit-code; then
    commit
  elif $strict; then
    print_error "no diff for $repo" 1
  fi

  popd
); }

main() {
  trap cleanup EXIT

  tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)

  get_opts "$@"
  validate_opts
  export_globals

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

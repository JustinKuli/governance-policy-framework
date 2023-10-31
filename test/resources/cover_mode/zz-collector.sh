#!/usr/bin/env bash

set -euo pipefail  # exit on errors and unset vars, and stop on the first error in a "pipeline"
if [[ -n "${PIPELINE_DEBUG}" ]]; then
  set -x # print commands as they're executed
  env
fi

# Use `err` to emit timestamped error messages
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

collect() {
  local repo=$1
  local branch=$2
  local treeish=$3

  if [[ -n "${branch}" ]]; then
    echo "Using ${repo} branch ${branch}"
    git clone "--branch=${branch}" "https://github.com/stolostron/${repo}.git"
  else
    echo "Using ${repo}'s default branch"
    git clone "https://github.com/stolostron/${repo}.git"
  fi
  cd "${repo}"

  if [[ -n "${treeish}" ]]; then
    echo "Using ${repo} tree-ish ${treeish}"
    git checkout "${treeish}"
  fi
  echo "Using ${repo} commit $(git rev-parse HEAD)"
  go tool covdata textfmt "-i=/tmp/covdata/${repo}" "-o=/tmp/covdata/${repo}/profile.txt"
  go tool cover "-func=/tmp/covdata/${repo}/profile.txt" "-o=/tmp/covdata/${repo}/func-coverage.txt"
  go tool cover "-html=/tmp/covdata/${repo}/profile.txt" "-o=/tmp/covdata/${repo}/coverage.html"
}

hub_collect() {
  mkdir -p /go/src/github.com/stolostron/
  
  cd /go/src/github.com/stolostron/
  collect "governance-policy-propagator" "${PROPAGATOR_BRANCH}" "${PROPAGATOR_TREEISH}"
}

managed_collect() {
  mkdir -p /go/src/github.com/stolostron/

  cd /go/src/github.com/stolostron/
  collect "cert-policy-controller" "${CERT_POLICY_BRANCH}" "${CERT_POLICY_TREEISH}"

  cd /go/src/github.com/stolostron/
  collect "config-policy-controller" "${CONFIG_POLICY_BRANCH}" "${CONFIG_POLICY_TREEISH}"

  cd /go/src/github.com/stolostron/
  collect "iam-policy-controller" "${IAM_POLICY_BRANCH}" "${IAM_POLICY_TREEISH}"

  mkdir -p /go/src/github.com/open-cluster-management-io

  cd /go/src/github.com/open-cluster-management-io/
  collect "governance-policy-framework-addon" "${POLICY_FW_ADDON_BRANCH}" "${POLICY_FW_ADDON_TREEISH}"
}

case "${1}" in
  "hub")
    hub_collect
    ;;
  "managed")
    managed_collect
    ;;
  *) echo "Unknown option ${1}"; exit 1 ;;
esac

echo "complete, sleeping"
sleep 3600

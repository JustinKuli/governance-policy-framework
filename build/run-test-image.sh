#!/bin/bash
# Copyright Contributors to the Open Cluster Management project

set -e

if [[ ${FAIL_FAST} == "true" ]]; then
  echo "* Running in fail fast mode"
  GINKGO_FAIL_FAST="--fail-fast" 
fi

if [[ -z ${GINKGO_LABEL_FILTER} ]]; then 
  echo "* No GINKGO_LABEL_FILTER set"
else
  GINKGO_LABEL_FILTER="--label-filter=${GINKGO_LABEL_FILTER}"
  echo "* Using GINKGO_LABEL_FILTER=${GINKGO_LABEL_FILTER}"
fi

if [[ -z ${OCM_NAMESPACE} ]]; then
  echo "* OCM_NAMESPACE not set, using open-cluster-management"
  OCM_NAMESPACE="open-cluster-management"
else
  echo "* Using OCM_NAMESPACE=${OCM_NAMESPACE}"
fi

if [[ -z ${OCM_ADDON_NAMESPACE} ]]; then
  echo "* OCM_ADDON_NAMESPACE not set, using open-cluster-management-agent-addon"
  OCM_ADDON_NAMESPACE="open-cluster-management-agent-addon"
else
  echo "* Using OCM_ADDON_NAMESPACE=${OCM_ADDON_NAMESPACE}"
fi

KMAN="--kubeconfig=/go/src/github.com/stolostron/governance-policy-framework/kubeconfig_managed"
KHUB="--kubeconfig=/go/src/github.com/stolostron/governance-policy-framework/kubeconfig_hub"

if [[ ${COVER_MODE} == "true" ]]; then
  # Pause the addons so the ManifestWorks can be edited
  oc ${KHUB} annotate managedclusteraddon -n ${MANAGED_CLUSTER_NAME} cert-policy-controller policy-addon-pause=true --overwrite
  oc ${KHUB} annotate managedclusteraddon -n ${MANAGED_CLUSTER_NAME} config-policy-controller policy-addon-pause=true --overwrite
  oc ${KHUB} annotate managedclusteraddon -n ${MANAGED_CLUSTER_NAME} governance-policy-framework policy-addon-pause=true --overwrite
  oc ${KHUB} annotate managedclusteraddon -n ${MANAGED_CLUSTER_NAME} iam-policy-controller policy-addon-pause=true --overwrite

  # Create the PVCs on the managed cluster for the coverage data
  oc ${KMAN} apply -n ${OCM_ADDON_NAMESPACE} -f test/resources/cover_mode/cert-pol-ctrl-covdata.pvc.yaml
  oc ${KMAN} apply -n ${OCM_ADDON_NAMESPACE} -f test/resources/cover_mode/config-pol-ctrl-covdata.pvc.yaml
  oc ${KMAN} apply -n ${OCM_ADDON_NAMESPACE} -f test/resources/cover_mode/gov-pol-fw-covdata.pvc.yaml
  oc ${KMAN} apply -n ${OCM_ADDON_NAMESPACE} -f test/resources/cover_mode/iam-pol-ctrl-covdata.pvc.yaml

  # Patch the ManifestWorks
  oc ${KHUB} patch manifestwork -n ${MANAGED_CLUSTER_NAME} addon-cert-policy-controller-deploy-0 --patch-file test/resources/cover_mode/cert-pol-ctrl-patch.json --type=json
  oc ${KHUB} patch manifestwork -n ${MANAGED_CLUSTER_NAME} addon-config-policy-controller-deploy-0 --patch-file test/resources/cover_mode/config-pol-ctrl-patch.json --type=json
  oc ${KHUB} patch manifestwork -n ${MANAGED_CLUSTER_NAME} addon-governance-policy-framework-deploy-0 --patch-file test/resources/cover_mode/gov-pol-fw-patch.json --type=json
  oc ${KHUB} patch manifestwork -n ${MANAGED_CLUSTER_NAME} addon-iam-policy-controller-deploy-0 --patch-file test/resources/cover_mode/iam-pol-ctrl-patch.json --type=json

  # Now the propagator
  oc ${KHUB} annotate MultiClusterHub multiclusterhub -n open-cluster-management mch-pause=true --overwrite
  oc ${KHUB} apply -n open-cluster-management -f test/resources/cover_mode/propagator-covdata.pvc.yaml
  oc ${KHUB} patch deployment -n open-cluster-management grc-policy-propagator --patch-file test/resources/cover_mode/propagator-patch.json --type=json

  # The addon-controller is not adjusted; it would basically just be paused in this setup anyway.
fi

# Run test suite with reporting
CGO_ENABLED=0 ./bin/ginkgo -v ${GINKGO_FAIL_FAST} ${GINKGO_LABEL_FILTER} --junit-report=integration.xml --output-dir=test-output test/integration -- -cluster_namespace=$MANAGED_CLUSTER_NAME -ocm_namespace=$OCM_NAMESPACE -ocm_addon_namespace=$OCM_ADDON_NAMESPACE -patch_decisions=false || EXIT_CODE=$?

if [[ ${COVER_MODE} == "true" ]]; then
  # Un-pause the addons so they get reverted (and the running pods gracefully exit)
  oc ${KHUB} annotate managedclusteraddon -n ${MANAGED_CLUSTER_NAME} cert-policy-controller policy-addon-pause-
  oc ${KHUB} annotate managedclusteraddon -n ${MANAGED_CLUSTER_NAME} config-policy-controller policy-addon-pause-
  oc ${KHUB} annotate managedclusteraddon -n ${MANAGED_CLUSTER_NAME} governance-policy-framework policy-addon-pause-
  oc ${KHUB} annotate managedclusteraddon -n ${MANAGED_CLUSTER_NAME} iam-policy-controller policy-addon-pause-

  oc ${KHUB} annotate MultiClusterHub multiclusterhub -n open-cluster-management mch-pause-
  # This doesn't fully restore the original configuration - additional patches are necessary :(

  # Create the analysis / collector pods
  oc ${KMAN} apply -n ${OCM_ADDON_NAMESPACE} -f test/resources/cover_mode/zz-grc-cov-collector.pod.yaml
  oc ${KHUB} apply -n open-cluster-management -f test/resources/cover_mode/zz-grc-cov-hub-collector.pod.yaml
fi

# Remove Gingko phases from report to prevent corrupting bracketed metadata
if [ -f test-output/integration.xml ]; then
  sed -i 's/\[It\] *//g' test-output/integration.xml
  sed -i 's/\[BeforeSuite\]/GRC: [P1][Sev1][policy-grc] BeforeSuite/g' test-output/integration.xml
  sed -i 's/\[AfterSuite\]/GRC: [P1][Sev1][policy-grc] AfterSuite/g' test-output/integration.xml
fi

# Collect exit code if it's an error
if [[ "${EXIT_CODE}" != "0" ]]; then
  ERROR_CODE=${EXIT_CODE}
fi

if [[ -n "${ERROR_CODE}" ]]; then
    echo "* Detected test failure. Collecting debug logs..."
    # For debugging, the managed cluster might have a different name (i.e. 'local-cluster') but the
    # kubeconfig is still called 'kubeconfig_managed'
    export MANAGED_CLUSTER_NAME="managed"
    make e2e-debug-acm
fi

# Since we may have captured an exit code previously, manually exit with it here
exit ${ERROR_CODE}

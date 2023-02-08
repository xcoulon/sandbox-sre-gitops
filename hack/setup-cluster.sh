#!/bin/bash -e

# Checking all prerequisites
ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"/..
if [ "$(oc auth can-i '*' '*' --all-namespaces)" != "yes" ]; then
  echo "[ERROR] User '$(oc whoami)' does not have the required 'cluster-admin' role." 1>&2
  echo "Log into the cluster with a user with the required privileges (e.g. kubeadmin) and retry."
  exit 1
fi
if [[ -z "${GITHUB_SANDBOX_SRE_GITOPS_URL}" ]]; then
  echo "[ERROR] GITHUB_SANDBOX_SRE_GITOPS_URL env is not set. Aborting."
  exit 1
fi
if [[ -z "${GITHUB_SANDBOX_SRE_GITOPS_USERNAME}" ]]; then
  echo "[ERROR] GITHUB_SANDBOX_SRE_GITOPS_USERNAME env is not set. Aborting."
  exit 1
fi
if [[ -z "${GITHUB_SANDBOX_SRE_GITOPS_TOKEN}" ]]; then
  echo "[ERROR] GITHUB_SANDBOX_SRE_GITOPS_TOKEN env is not set. Aborting."
  exit 1
fi

# ---------------------------------------------------------------------------------------------
# OpenShift GitOps Operator
# ---------------------------------------------------------------------------------------------
echo "🛠  Installing the OpenShift GitOps operator..."
kubectl apply --kustomize $ROOT/openshift-gitops
echo -n "⏱  Waiting for Argo CD to be available..."
while ! kubectl get appproject/default -n openshift-gitops &> /dev/null ; do
  echo -n .
  sleep 1
done
echo "OK"

echo -n "⏱  Waiting for OpenShift GitOps Service Account..."
while ! kubectl get sa/openshift-gitops-argocd-application-controller -n openshift-gitops &> /dev/null ; do
  echo -n .
  sleep 1
done
echo "OK"

# grant `clusterrole/edit` to `system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller` 
# so the latter can create secrets and other custom resources
oc adm policy add-cluster-role-to-user edit system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller 

# ---------------------------------------------------------------------------------------------
# GitHub Repository
# ---------------------------------------------------------------------------------------------
# Note: commands can be run multiple times without failing when the
# secret already exists and is already annotated and labelled.
# ---------------------------------------------------------------------------------------------
echo "🛠  Configuring the GitHub repository..."
oc create secret generic repo-sandbox-sre-gitops -n openshift-gitops \
  --from-literal=project=default \
  --from-literal=name=sandbox-sre-gitops \
  --from-literal=url=$GITHUB_SANDBOX_SRE_GITOPS_URL \
  --from-literal=username=$GITHUB_SANDBOX_SRE_GITOPS_USERNAME \
  --from-literal=password=$GITHUB_SANDBOX_SRE_GITOPS_TOKEN \
  --dry-run=client -o yaml | oc apply -f -
oc annotate --overwrite=true secret/repo-sandbox-sre-gitops -n openshift-gitops \
  managed-by=argocd.argoproj.io 
oc label --overwrite=true secret/repo-sandbox-sre-gitops -n openshift-gitops \
  argocd.argoproj.io/secret-type=repository

# ---------------------------------------------------------------------------------------------
# ArgoCD Applications
# ---------------------------------------------------------------------------------------------
echo "🛠  Creating the Argo CD Applications..."
oc apply --kustomize $ROOT/argocd-apps/base

# ---------------------------------------------------------------------------------------------
# ArgoCD Web UI
# ---------------------------------------------------------------------------------------------
echo "👋 all done!"
ARGO_CD_ROUTE=$(oc get -n openshift-gitops -o go-template={{.spec.host}} route/openshift-gitops-server)
echo "📺 ArgoCD dashboard is available on https://${ARGO_CD_ROUTE}"
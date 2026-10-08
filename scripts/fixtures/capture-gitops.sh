#!/bin/sh
# Captures real kustomize and helm renders of the GitOps fixture repos into
# tests/fixtures/gitops/captured/ so index specs feed addRendered genuine
# tool output. Rendering needs no cluster; KUBECONFIG still points at the
# sandbox so kubectl can never fall back to the user's config.
set -eu

cd "$(dirname "$0")/../.."

KUBECTL=${KUBECTL:-kubectl}
HELM=${HELM:-.tools/bin/helm}
src=tests/fixtures/gitops
out=$src/captured
export KUBECONFIG="$PWD/.sandbox/kubeconfig"

[ -x "$HELM" ] || {
	echo "capture-gitops: $HELM missing; run 'make bootstrap'" >&2
	exit 1
}

mkdir -p "$out"
"$KUBECTL" kustomize "$src/kustomize/overlays/staging" >"$out/kustomize-staging.yaml"
"$KUBECTL" kustomize "$src/kustomize/overlays/prod" >"$out/kustomize-prod.yaml"
"$HELM" template web "$src/helm/chart" -n tern-test-helm -f "$src/helm/values-staging.yaml" >"$out/helm-web.yaml"
{
	printf 'kubectl: %s\n' "$("$KUBECTL" version --client 2>/dev/null | tr '\n' ' ')"
	printf 'helm: %s\n' "$("$HELM" version --short)"
} >"$out/VERSIONS.txt"

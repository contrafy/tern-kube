#!/bin/sh
# Captures real drift and GitOps-controller fixtures for plugin/lib/gitops
# specs and the kube-lens-drift CLI into tests/fixtures/drift/:
#
#   <scenario>/<key>.txt|.stderr|.exit  raw `kubectl diff` (exit always kept)
#   live/<key>.json                     live objects for unmanaged detection
#   controllers/<key>.json|.list        Argo CD / Flux objects + api-resources
#   manifests/**                        copy of the diffed manifests (the source)
#   MANIFEST.tsv                        scenario, key, argv, exit, versions
#
#   scripts/fixtures/capture-drift.sh
#
# Writes to the sandbox kind cluster only, and only to: the tern-test-drift and
# tern-test-gitops namespaces (recreated from scratch on every run), plus the
# vendored GitOps CRDs (tests/integration/manifests/gitops-crds, digests
# checked against its README). Drift is produced by applying
# tests/integration/manifests/drift/{namespace.yaml,baseline/} and then
# scaling/patching live objects; drift/pending/ is never applied, so it shows
# up as "missing in cluster". No controller is installed: Argo CD Application
# status is patched through the main resource (the CRD has no status
# subresource), Flux status through --subresource=status.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
MANIFESTS=$ROOT/tests/integration/manifests
CRDS=$MANIFESTS/gitops-crds
OUT=$ROOT/tests/fixtures/drift
MANIFEST=$OUT/MANIFEST.tsv
KUBECTL=${KUBECTL:-kubectl}
CONTEXT=kind-kube-lens-dev
DRIFT_NS=tern-test-drift
GITOPS_NS=tern-test-gitops

die() {
	printf 'capture-drift: %s\n' "$*" >&2
	exit 1
}

KUBECONFIG=$("$ROOT/scripts/cluster.sh" kubeconfig-path) || die "sandbox cluster is not usable; run scripts/cluster.sh create"
export KUBECONFIG
KUBERC=off
TMPDIR=/tmp
export KUBERC TMPDIR
unset KUBECTL_EXTERNAL_DIFF KUBECTL_EXPLICIT_LOCAL_PERMISSIONS 2>/dev/null || true

kc() {
	(cd "$MANIFESTS" && "$KUBECTL" --context "$CONTEXT" "$@")
}

# Namespaced writes go through here: the namespace must be one of ours.
kn() {
	ns=$1
	shift
	case $ns in "$DRIFT_NS" | "$GITOPS_NS") ;; *) die "refusing write outside $DRIFT_NS/$GITOPS_NS: $ns" ;; esac
	kc -n "$ns" "$@" >/dev/null
}

version_of() {
	sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -n 1
}

CLIENT_VERSION=$(kc version --client -o json | version_of)
SERVER_VERSION=$(kc get --raw /version | version_of)
[ -n "$CLIENT_VERSION" ] && [ -n "$SERVER_VERSION" ] || die "could not determine kubectl/server versions"

fixture_key() {
	key=""
	skip=0
	for arg in "$@"; do
		if [ "$skip" = 1 ]; then
			skip=0
			continue
		fi
		case $arg in
		--context | --kubeconfig | -n | --namespace | --cluster | --user)
			skip=1
			continue
			;;
		--context=* | --kubeconfig=* | --namespace=* | --cluster=* | --user=* | -n?*)
			continue
			;;
		esac
		part=$(printf '%s' "$arg" | tr '/' '+')
		if [ -z "$key" ]; then
			key=$part
		else
			key=${key}_$part
		fi
	done
	printf '%s' "$key"
}

argv_string() {
	line=kubectl
	for arg in "$@"; do
		case $arg in
		*[!A-Za-z0-9_./=:,+-]*) arg="'$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")'" ;;
		esac
		line="$line $arg"
	done
	printf '%s' "$line"
}

# The kube-root-ca.crt ConfigMap is public, but no certificate material is
# kept in fixtures.
redact() {
	sed 's/\("ca\.crt": \)".*"/\1"REDACTED"/'
}

mismatches=0

record() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$CLIENT_VERSION" "$SERVER_VERSION" >>"$MANIFEST"
}

# diffcap SCENARIO EXPECTED_EXIT KUBECTL_DIFF_ARGS... (read-only)
diffcap() {
	scenario=$1 expect=$2
	shift 2
	[ "$1" = diff ] || die "diffcap only runs kubectl diff"
	set -- --context "$CONTEXT" "$@"
	key=$(fixture_key "$@")
	mkdir -p "$OUT/$scenario"
	base=$OUT/$scenario/$key
	[ ! -e "$base.txt" ] || die "duplicate fixture key $scenario/$key"
	set +e
	(cd "$MANIFESTS" && "$KUBECTL" "$@") >"$base.txt" 2>"$base.stderr"
	status=$?
	set -e
	[ -s "$base.stderr" ] || rm -f "$base.stderr"
	printf '%s\n' "$status" >"$base.exit"
	record "$scenario" "$scenario/$key" "$(argv_string "$@")" "$status"
	if [ "$status" != "$expect" ]; then
		mismatches=$((mismatches + 1))
		printf 'capture-drift: UNEXPECTED exit %s (wanted %s): %s\n' "$status" "$expect" "$(argv_string "$@")" >&2
		[ -f "$base.stderr" ] && sed 's/^/    /' "$base.stderr" >&2
	fi
	return 0
}

# getcap DIR NAME EXT KUBECTL_READ_ARGS... (get / api-resources only)
getcap() {
	dir=$1 name=$2 ext=$3
	shift 3
	case $1 in get | api-resources) ;; *) die "getcap only runs read verbs" ;; esac
	set -- --context "$CONTEXT" "$@"
	mkdir -p "$OUT/$dir"
	"$KUBECTL" "$@" | redact >"$OUT/$dir/$name.$ext"
	record "$dir" "$dir/$name.$ext" "$(argv_string "$@")" 0
}

check_crds() {
	(cd "$CRDS" && for f in *.yaml; do
		want=$(sed -n "s/^| $f | [^|]* | \([0-9a-f]\{64\}\) |\$/\1/p" README.md)
		got=$(shasum -a 256 "$f" | cut -d' ' -f1)
		[ -n "$want" ] || die "$f is not listed in gitops-crds/README.md"
		[ "$want" = "$got" ] || die "$f digest $got does not match README ($want)"
	done)
}

# ---- reset -----------------------------------------------------------------
check_crds
kc delete namespace "$DRIFT_NS" "$GITOPS_NS" --ignore-not-found --wait=true --timeout=180s >/dev/null
kc apply --server-side --force-conflicts -f gitops-crds/ >/dev/null
kc wait --for=condition=Established --timeout=60s \
	crd/applications.argoproj.io \
	crd/kustomizations.kustomize.toolkit.fluxcd.io \
	crd/helmreleases.helm.toolkit.fluxcd.io \
	crd/gitrepositories.source.toolkit.fluxcd.io >/dev/null

# ---- drift world -----------------------------------------------------------
kc apply -f drift/namespace.yaml >/dev/null
kn "$DRIFT_NS" apply -f drift/baseline/
kn "$DRIFT_NS" rollout status deployment/web --timeout=180s
# unmanaged: exists only in the cluster
kn "$DRIFT_NS" create configmap hand-made --from-literal=owner=someone
# changed: scale, edit data, edit a CRD object, relabel the namespace
kn "$DRIFT_NS" scale deployment/web --replicas=2
kn "$DRIFT_NS" patch configmap app-config --type=merge -p '{"data":{"LOG_LEVEL":"debug"}}'
kn "$DRIFT_NS" patch widgets.lens.example.com gauge --type=merge -p '{"spec":{"color":"orange","size":9}}'
kc patch namespace "$DRIFT_NS" --type=merge -p '{"metadata":{"labels":{"team":"payments"}}}' >/dev/null
kn "$DRIFT_NS" rollout status deployment/web --timeout=180s

# ---- gitops world ----------------------------------------------------------
kc apply -f gitops/namespace.yaml >/dev/null
kn "$GITOPS_NS" apply -f gitops/controllers.yaml -f gitops/workloads/
for app in guestbook guestbook-drifted charted; do
	kn "$GITOPS_NS" patch applications.argoproj.io "$app" --type=merge --patch-file "gitops/status/application-$app.json"
done
kn "$GITOPS_NS" patch gitrepositories.source.toolkit.fluxcd.io kube-lens --subresource=status --type=merge \
	--patch-file gitops/status/gitrepository-kube-lens.json
for ks in apps drift; do
	kn "$GITOPS_NS" patch kustomizations.kustomize.toolkit.fluxcd.io "$ks" --subresource=status --type=merge \
		--patch-file "gitops/status/kustomization-$ks.json"
done
kn "$GITOPS_NS" patch helmreleases.helm.toolkit.fluxcd.io podinfo --subresource=status --type=merge \
	--patch-file gitops/status/helmrelease-podinfo.json

# ---- capture (read-only from here on) --------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$MANIFESTS/drift" "$OUT/manifests"
printf 'scenario\tkey\targv\texit\tkubectl_version\tserver_version\n' >"$MANIFEST"

diffcap changed 1 diff -f drift/baseline/app.yaml
diffcap unchanged 0 diff -f drift/baseline/service.yaml
diffcap crd 1 diff -f drift/baseline/widgets.yaml
diffcap missing 1 diff -f drift/pending/extra.yaml
diffcap cluster-scoped 1 diff -f drift/namespace.yaml
diffcap source 1 diff -R -f drift

getcap live objects json get deployments.apps,replicasets.apps,configmaps,services,serviceaccounts,widgets.lens.example.com \
	-n "$DRIFT_NS" -o json

getcap controllers api-resources list api-resources --verbs=list -o name
getcap controllers applications json get applications.argoproj.io -n "$GITOPS_NS" -o json
getcap controllers kustomizations json get kustomizations.kustomize.toolkit.fluxcd.io -n "$GITOPS_NS" -o json
getcap controllers helmreleases json get helmreleases.helm.toolkit.fluxcd.io -n "$GITOPS_NS" -o json
getcap controllers gitrepositories json get gitrepositories.source.toolkit.fluxcd.io -n "$GITOPS_NS" -o json
getcap controllers workloads json get configmaps,services -n "$GITOPS_NS" -o json

if grep -rlE 'BEGIN (RSA |EC )?PRIVATE KEY|BEGIN CERTIFICATE|client-key-data|token:' "$OUT" >/dev/null 2>&1; then
	die "credential material leaked into $OUT"
fi
[ "$mismatches" = 0 ] || die "$mismatches capture(s) exited unexpectedly"
printf '==> captured %s fixtures into %s\n' "$(($(wc -l <"$MANIFEST") - 1))" "$OUT" >&2

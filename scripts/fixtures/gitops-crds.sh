#!/bin/sh
# The vendored Argo CD / Flux CRDs (tests/integration/manifests/gitops-crds)
# on the sandbox kind cluster. Every install checks the files' sha256 against
# the README table first; nothing else is ever applied.
#
#   scripts/fixtures/gitops-crds.sh check                 verify the digests only
#   scripts/fixtures/gitops-crds.sh install [MARKER]      apply (server-side) unless every CRD
#                                                         exists; writes MARKER when it applied
#   scripts/fixtures/gitops-crds.sh remove-if-installed MARKER
#                                                         delete the CRDs only when MARKER says
#                                                         this run installed them
#
# KUBECONFIG must be the sandbox one (scripts/cluster.sh kubeconfig-path is
# used when it is unset); the context is always kind-tern-kube-dev.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
CRDS=$ROOT/tests/integration/manifests/gitops-crds
KUBECTL=${KUBECTL:-kubectl}
CONTEXT=kind-tern-kube-dev
NAMES="applications.argoproj.io kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io gitrepositories.source.toolkit.fluxcd.io"

die() {
	printf 'gitops-crds: %s\n' "$*" >&2
	exit 1
}

sandbox_kubeconfig() {
	case ${KUBECONFIG:-} in
	'') KUBECONFIG=$("$ROOT/scripts/cluster.sh" kubeconfig-path) || die "sandbox cluster is not usable" ;;
	"$ROOT/.sandbox/kubeconfig" | "$ROOT/.sandbox/kubeconfig-mc") ;;
	*) die "KUBECONFIG must be $ROOT/.sandbox/kubeconfig (is $KUBECONFIG)" ;;
	esac
	export KUBECONFIG
}

kc() {
	"$KUBECTL" --context "$CONTEXT" "$@"
}

check() {
	(cd "$CRDS" && for f in *.yaml; do
		want=$(sed -n "s/^| $f | [^|]* | \([0-9a-f]\{64\}\) |\$/\1/p" README.md)
		got=$(shasum -a 256 "$f" | cut -d' ' -f1)
		[ -n "$want" ] || die "$f is not listed in gitops-crds/README.md"
		[ "$want" = "$got" ] || die "$f digest $got does not match README ($want)"
	done)
}

all_present() {
	for n in $NAMES; do
		kc get crd "$n" >/dev/null 2>&1 || return 1
	done
}

install() {
	check
	sandbox_kubeconfig
	if all_present; then
		return 0
	fi
	kc apply --server-side --force-conflicts -f "$CRDS/" >/dev/null
	# shellcheck disable=SC2086
	kc wait --for=condition=Established --timeout=60s $(printf 'crd/%s ' $NAMES) >/dev/null
	if [ -n "${1:-}" ]; then
		printf 'installed\n' >"$1"
	fi
}

remove_if_installed() {
	[ -n "${1:-}" ] || die "remove-if-installed needs the marker file"
	[ -f "$1" ] || return 0
	sandbox_kubeconfig
	# shellcheck disable=SC2086
	kc delete crd $NAMES --ignore-not-found --wait=true --timeout=120s >/dev/null
	rm -f "$1"
}

case ${1:-} in
check) check ;;
install) install "${2:-}" ;;
remove-if-installed) remove_if_installed "${2:-}" ;;
*)
	printf 'usage: %s check|install [MARKER]|remove-if-installed MARKER\n' "$0" >&2
	exit 2
	;;
esac

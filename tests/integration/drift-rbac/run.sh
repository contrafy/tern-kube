#!/bin/sh
# Verifies on the kind cluster that examples/ci/rbac-drift-readonly.yaml is
# enough for bin/kube-lens-drift and that it cannot mutate anything:
#   - the shipped example, renamed into namespace tern-test-drift-rbac, lets
#     a ServiceAccount token report modify + create drift and --unmanaged;
#   - every real write from that token (apply, create, patch, scale,
#     rollout restart, annotate, delete) is rejected and the live objects are
#     unchanged afterwards;
#   - each verb is necessary: without get or patch the diff fails, without
#     create only objects missing from the cluster fail, without list only
#     --unmanaged fails.
#
#   sh tests/integration/drift-rbac/run.sh [--keep]
#
# Only touches the kind cluster through .sandbox/kubeconfig (verified by
# scripts/cluster.sh), namespace tern-test-drift-rbac and cluster-scoped
# objects named tern-test-drift-rbac*. Token kubeconfigs (2h) are written to
# .sandbox/drift-rbac/. Everything is deleted at the end unless --keep.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd -P)
KC=$(sh "$ROOT/scripts/cluster.sh" kubeconfig-path) || exit 2
CTX=kind-kube-lens-dev
NS=tern-test-drift-rbac
SA_USER=system:serviceaccount:$NS:$NS
OUT=$ROOT/.sandbox/drift-rbac
CLI=$ROOT/bin/kube-lens-drift
keep=0
[ "${1:-}" = --keep ] && keep=1

pass=0
failed=0
ok() {
	pass=$((pass + 1))
	printf 'ok   %s\n' "$*"
}
bad() {
	failed=$((failed + 1))
	printf 'FAIL %s\n' "$*"
	[ -s "$work/out" ] && sed 's/^/    | /' "$work/out" | head -n 20
}

admin() {
	KUBECONFIG=$KC kubectl --kubeconfig "$KC" --context "$CTX" "$@"
}

# as SA ARGS...: kubectl with only the ServiceAccount's token.
as() {
	sa_=$1
	shift
	KUBECONFIG=$OUT/$sa_.kubeconfig kubectl --kubeconfig "$OUT/$sa_.kubeconfig" "$@"
}

# drift SA ARGS...: the CLI with only the ServiceAccount's token; sets $rc.
drift() {
	sa_=$1
	shift
	KUBECONFIG=$OUT/$sa_.kubeconfig "$CLI" --kubeconfig "$OUT/$sa_.kubeconfig" "$@" >"$work/out" 2>&1
	rc=$?
}

work=$(mktemp -d "${TMPDIR:-/tmp}/kld-rbac.XXXXXX") || exit 2

example() {
	sed -e "s/kube-lens-drift/$NS/g" -e "s/my-app/$NS/g" "$ROOT/examples/ci/rbac-drift-readonly.yaml"
}

# Variants that each drop one verb, to show it is needed. They are not
# covered by the dry-run-only policy and are only ever used for diffs.
variant() { # NAME VERBS [API_GROUPS RESOURCES]
	groups_=${3:-'"", apps'}
	resources_=${4:-configmaps, deployments}
	cat <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $1
  namespace: $NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $1
  namespace: $NS
rules:
  - apiGroups: [$groups_]
    resources: [$resources_]
    verbs: [$2]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $1
  namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: $1
subjects:
  - kind: ServiceAccount
    name: $1
    namespace: $NS
EOF
}

variants() {
	variant kl-no-get "list, create, patch"
	variant kl-no-patch "get, list, create"
	variant kl-no-create "get, list, patch"
	variant kl-no-list "get, create, patch"
	variant kl-rbac-objects "get, list, create, patch" rbac.authorization.k8s.io roles
}

live_state() {
	cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: seed
  namespace: $NS
data:
  level: live
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hand-made
  namespace: $NS
data:
  note: created outside git
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: web
          image: registry.k8s.io/pause:3.10
EOF
}

git_state() {
	mkdir -p "$work/git/existing" "$work/git/missing"
	cat >"$work/git/existing/app.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: seed
  namespace: $NS
data:
  level: git
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: $NS
spec:
  replicas: 2
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: web
          image: registry.k8s.io/pause:3.10
EOF
	cat >"$work/git/missing/only-in-git.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: only-in-git
  namespace: $NS
data:
  level: git
EOF
}

kubeconfig_for() { # SA
	server=$(admin config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
	ca=$(admin config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
	token=$(admin -n "$NS" create token "$1" --duration=2h) || return 1
	(
		umask 077
		cat >"$OUT/$1.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: kind-kube-lens-dev
    cluster:
      server: $server
      certificate-authority-data: $ca
users:
  - name: $1
    user:
      token: $token
contexts:
  - name: $1@kind-kube-lens-dev
    context:
      cluster: kind-kube-lens-dev
      user: $1
      namespace: $NS
current-context: $1@kind-kube-lens-dev
EOF
	)
}

cleanup() {
	if [ "$keep" = 0 ]; then
		{ example; variants; } | admin delete --ignore-not-found --wait=false -f - >/dev/null 2>&1
		admin delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
		rm -rf "$OUT"
	fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 2' HUP INT TERM

snapshot() {
	admin -n "$NS" get configmap seed -o jsonpath='{.data.level} {.metadata.resourceVersion}'
	printf ' '
	# generation, not resourceVersion: the controller keeps updating status.
	admin -n "$NS" get deployment web -o jsonpath='{.spec.replicas} {.metadata.generation} {.metadata.labels} {.metadata.annotations} {.spec.template.metadata.annotations}'
	printf ' '
	admin -n "$NS" get configmap only-in-git -o name --ignore-not-found
	admin -n "$NS" get configmap made-by-ci -o name --ignore-not-found
}

# --- Setup ----------------------------------------------------------------

mkdir -p "$OUT"
chmod 700 "$OUT"
admin wait --for=delete "namespace/$NS" --timeout=180s >/dev/null 2>&1
admin create namespace "$NS" --dry-run=client -o yaml | admin apply -f - >/dev/null || exit 2
{
	example
	variants
} | admin apply -f - >/dev/null || exit 2
live_state | admin apply -f - >/dev/null || exit 2
git_state
for sa in "$NS" kl-no-get kl-no-patch kl-no-create kl-no-list kl-rbac-objects; do
	kubeconfig_for "$sa" || exit 2
done
# RBAC alone would allow these writes; only the admission policy stops them.
[ "$(as "$NS" -n "$NS" auth can-i patch configmaps 2>/dev/null)" = yes ] &&
	ok "RBAC alone grants patch (the dry-run-only policy is what makes it read-only)" ||
	bad "expected RBAC to grant patch"
# The policy binding takes effect asynchronously; wait until a real write
# from the token is rejected (and fail if that never happens).
i=0
until ! as "$NS" -n "$NS" annotate configmap seed probe=1 >/dev/null 2>&1; do
	admin -n "$NS" annotate configmap seed probe- >/dev/null 2>&1
	i=$((i + 1))
	[ "$i" -lt 30 ] || {
		bad "dry-run-only policy never took effect"
		exit 1
	}
	sleep 1
done
before=$(snapshot)

# --- The example's ServiceAccount reports drift ----------------------------

drift "$NS" -R -f "$work/git" --format json
[ "$rc" = 1 ] && ok "example RBAC: drift reported (exit 1)" || bad "example RBAC: exit $rc, want 1"
grep -q '"name":"seed","action":"modify"' "$work/out" && ok "example RBAC: changed ConfigMap is modify" || bad "seed not modify"
grep -q '"name":"web","action":"modify"' "$work/out" && ok "example RBAC: changed Deployment is modify" || bad "web not modify"
grep -q '"name":"only-in-git","action":"create"' "$work/out" && ok "example RBAC: object missing from the cluster is create" || bad "only-in-git not create"

drift "$NS" -R -f "$work/git" --unmanaged auto --format json
[ "$rc" = 1 ] && grep -q '"kind":"ConfigMap","namespace":"'"$NS"'","name":"hand-made"' "$work/out" &&
	ok "example RBAC: --unmanaged lists hand-made ConfigMap" || bad "example RBAC --unmanaged: exit $rc"

# --- ...and cannot write ----------------------------------------------------

denied() { # WHAT ARGS...
	what_=$1
	shift
	if as "$NS" -n "$NS" "$@" >"$work/out" 2>&1; then
		bad "example RBAC could $what_"
	else
		ok "example RBAC cannot $what_: $(grep -o 'denied request: .*\|forbidden: .*' "$work/out" | head -n 1 | cut -c1-90)"
	fi
}
denied "apply manifests" apply -R -f "$work/git"
denied "server-side apply" apply --server-side -R -f "$work/git"
denied "create" create configmap made-by-ci --from-literal=a=b
denied "patch" patch configmap seed --type=merge -p '{"data":{"level":"ci"}}'
denied "annotate" annotate configmap seed touched=1
denied "scale" scale deployment web --replicas=3
denied "rollout restart" rollout restart deployment web
denied "delete" delete configmap seed
denied "replace" replace -f "$work/git/existing/app.yaml"
after=$(snapshot)
[ "$before" = "$after" ] && ok "live objects unchanged after every attempt" || bad "live state changed: '$before' -> '$after'"
if as "$NS" -n "$NS" create configmap dry --from-literal=a=b --dry-run=server >/dev/null 2>&1; then
	ok "example RBAC: server dry-run still allowed"
else
	bad "example RBAC: server dry-run rejected"
fi

# --- Each verb is necessary -------------------------------------------------

drift kl-no-get -R -f "$work/git"
[ "$rc" = 2 ] && grep -q 'cannot get resource' "$work/out" && ok "without get: diff fails (exit 2)" || bad "without get: exit $rc, want 2"
drift kl-no-patch -f "$work/git/existing"
[ "$rc" = 2 ] && grep -q 'cannot patch resource' "$work/out" && ok "without patch: diff of existing objects fails (exit 2)" ||
	bad "without patch: exit $rc, want 2"
drift kl-no-create -f "$work/git/missing"
[ "$rc" = 2 ] && grep -q 'cannot create resource' "$work/out" && ok "without create: missing objects cannot be reported (exit 2)" ||
	bad "without create (missing): exit $rc, want 2"
drift kl-no-create -f "$work/git/existing"
[ "$rc" = 1 ] && ok "without create: existing objects still diff (exit 1)" || bad "without create (existing): exit $rc, want 1"
drift kl-no-list -R -f "$work/git"
[ "$rc" = 1 ] && ok "without list: plain drift works (exit 1)" || bad "without list: exit $rc, want 1"
drift kl-no-list -R -f "$work/git" --unmanaged auto
[ "$rc" = 2 ] && grep -q 'cannot list resource' "$work/out" && ok "without list: --unmanaged fails (exit 2)" ||
	bad "without list --unmanaged: exit $rc, want 2"

# Diffing RBAC objects needs more than get/create/patch: the API server
# checks privilege escalation on dry runs too.
cat >"$work/role.yaml" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: reads-secrets
  namespace: $NS
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get]
EOF
drift kl-rbac-objects -f "$work/role.yaml"
[ "$rc" = 2 ] && grep -q 'attempting to grant RBAC permissions not currently held' "$work/out" &&
	ok "Roles: get/create/patch is not enough (escalation check, exit 2)" ||
	bad "Roles without escalate: exit $rc, want 2"

printf '\n%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" = 0 ]

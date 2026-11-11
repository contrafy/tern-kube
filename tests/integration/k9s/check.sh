#!/bin/sh
# Guards the k9s-parity lens views against kubectl/server format drift: runs
# `rollout history` (list and --revision), `config get-contexts`,
# `api-resources` (plus Explore's exact discovery argv) and `auth can-i`
# (single and --list) live, feeds the output (revision text raw and
# tab-expanded, as a terminal grid shows it) through Capture.build and
# Discovery.parse, and checks rows and revisions against what kubectl reports
# by other means. No kubectl message may become a row.
#
# Writes only inside its own namespace tern-test-k9s-check (created here,
# deleted on exit, also on failure) and a private multi-context kubeconfig in
# a temp dir. Pinned to the sandbox kubeconfig and the kind context.
#
#   sh tests/integration/k9s/check.sh
set -eu

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
CTX=kind-tern-kube-dev
NS=tern-test-k9s-check
LUAU=$REPO/.tools/bin/luau

cd "$REPO"
SANDBOX_KUBECONFIG=$(sh scripts/cluster.sh kubeconfig-path)
KUBECONFIG=$SANDBOX_KUBECONFIG
export KUBECONFIG
KUBERC=off
export KUBERC

kc() {
	kubectl --context "$CTX" "$@"
}

WORK=$(mktemp -d "$REPO/tests/integration/k9s/.work.XXXXXX")
cleanup() {
	KUBECONFIG=$SANDBOX_KUBECONFIG kubectl --context "$CTX" delete namespace "$NS" --ignore-not-found --wait=true \
		--timeout=120s >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: $NS
  annotations:
    kubernetes.io/change-cause: "first: pause 3.10"
spec:
  replicas: 1
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: viewer
  namespace: $NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: viewer-view
  namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: viewer
    namespace: $NS
EOF
kc -n "$NS" rollout status deployment/web --timeout=180s >/dev/null
kc -n "$NS" set image deployment/web pause=registry.k8s.io/pause:3.9 >/dev/null
kc -n "$NS" annotate --overwrite deployment/web 'kubernetes.io/change-cause=second (3.9)' >/dev/null
kc -n "$NS" rollout status deployment/web --timeout=180s >/dev/null
kc -n "$NS" set env deployment/web MODE=x >/dev/null
kc -n "$NS" rollout status deployment/web --timeout=180s >/dev/null

MULTI=$WORK/multi.kubeconfig
kc config view --raw --minify --flatten >"$MULTI"
mk() {
	kubectl --kubeconfig "$MULTI" config "$@" >/dev/null
}
mk set-context tk-apps --cluster="$CTX" --user="$CTX" --namespace=tern-test-apps
mk set-context "tk spaced" --cluster="$CTX" --user="$CTX"
mk set-context "arn:aws:eks:us-east-1:123456789012:cluster/prod" --cluster="$CTX" --user="$CTX"
mk use-context "$CTX"

# Long-bracket level that cannot occur in the text, as scripts/fixtures/embed.sh does.
embed() {
	eq="="
	while grep -qF "]$eq" "$1"; do
		eq="$eq="
	done
	printf '[%s[\n' "$eq"
	cat "$1"
	printf ']%s]' "$eq"
}

n=0
DRIVER=$WORK/main.luau
{
	printf -- '--!strict\n'
	printf 'local check = require("../check")\n'
	printf 'check({\n'
} >"$DRIVER"

# form NAME TRUTH_FILE COMMAND_WORDS... : runs kubectl (KUBECONFIG from the
# environment), stdout then stderr as the lens gets them.
form() {
	name=$1 truth=$2
	shift 2
	n=$((n + 1))
	set +e
	kubectl "$@" >"$WORK/$n.out" 2>"$WORK/$n.err"
	status=$?
	set -e
	cat "$WORK/$n.out" "$WORK/$n.err" >"$WORK/$n.txt"
	expand -t 8 "$WORK/$n.out" >"$WORK/$n.exp"
	cat "$WORK/$n.err" >>"$WORK/$n.exp"
	# argv one word per line, so no word is split again.
	printf '%s\n' "$@" >"$WORK/$n.cmd"
	{
		printf '\t{ name = "%s", status = %d,\n\t\tcommand = ' "$name" "$status"
		embed "$WORK/$n.cmd"
		printf ',\n\t\ttext = '
		embed "$WORK/$n.txt"
		printf ',\n\t\texpanded = '
		embed "$WORK/$n.exp"
		printf ',\n\t\tstdout = '
		embed "$WORK/$n.out"
		printf ',\n\t\ttruth = '
		embed "$truth"
		printf ' },\n'
	} >>"$DRIVER"
}

T=$WORK/truth
# History truth: the revision annotations of the Deployment's ReplicaSets.
kc -n "$NS" get rs -l app=web -o jsonpath='{range .items[*]}{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\n"}{end}' |
	sort -n >"$T.revisions"
form history "$T.revisions" --context "$CTX" -n "$NS" rollout history deployment/web
for rev in $(cat "$T.revisions"); do
	kc -n "$NS" get rs -l app=web -o jsonpath="{range .items[?(@.metadata.annotations.deployment\.kubernetes\.io/revision==\"$rev\")]}{.spec.template.spec.containers[0].image}{end}" >"$T.image$rev"
	form revision "$T.image$rev" --context "$CTX" -n "$NS" rollout history deployment/web "--revision=$rev"
done

KUBECONFIG=$MULTI
kubectl config get-contexts -o name >"$T.contexts"
form contexts "$T.contexts" config get-contexts
form contexts "$T.contexts" config get-contexts --no-headers
form contexts "$T.contexts" config get-contexts -o name
form contexts "$T.contexts" --context tk-apps config get-contexts
KUBECONFIG=$SANDBOX_KUBECONFIG

kc api-resources -o name | sort >"$T.resources"
kc api-resources --verbs=list -o name | sort >"$T.listable"
form apiresources "$T.resources" --context "$CTX" api-resources
form apiresources "$T.resources" --context "$CTX" api-resources -o wide
form apiresources "$T.resources" --context "$CTX" api-resources -o name
form discovery "$T.listable" --context "$CTX" api-resources --verbs=list -o wide

SA=system:serviceaccount:$NS:viewer
answer() {
	if kc "$@" -q >/dev/null 2>&1; then echo yes; else echo no; fi
}
for q in "get pods" "delete pods" "list secrets" "get frobs"; do
	# shellcheck disable=SC2086
	answer "--as=$SA" -n "$NS" auth can-i $q >"$T.answer"
	# shellcheck disable=SC2086
	form cani "$T.answer" --context "$CTX" "--as=$SA" -n "$NS" auth can-i $q
	# shellcheck disable=SC2086
	form cani "$T.answer" --context "$CTX" "--as=$SA" -n "$NS" auth can-i $q -q
done
kc "--as=$SA" -n "$NS" auth can-i --list --no-headers | grep -c . >"$T.rules" || true
form canilist "$T.rules" --context "$CTX" "--as=$SA" -n "$NS" auth can-i --list
kc auth can-i --list --no-headers | grep -c . >"$T.adminrules" || true
form canilist "$T.adminrules" --context "$CTX" auth can-i --list

{
	printf '})\n'
	printf 'return nil\n'
} >>"$DRIVER"

# The driver sits in a work dir next to check.luau: luau resolves requires
# relative to the requiring file.
"$LUAU" "$DRIVER"
echo "k9s check: ok ($n forms)"

#!/bin/sh
# Mutation integration scenarios against the kind cluster: the approve
# block's pure session driven by harness.sh with real kubectl results.
# Everything targets context kind-kube-lens-dev through .sandbox kubeconfigs
# and only namespace tern-test-mutate. Evidence per scenario lands in
# .sandbox/mutate-it/<scenario>/{evidence.log,view.txt,effects.log,audit.log}.
#
#   tests/integration/mutate/run.sh [SCENARIO...]   (default: all)
set -u

KL_REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
export KL_REPO
KC=$(sh "$KL_REPO/scripts/cluster.sh" kubeconfig-path) || exit 1
# Every process below (harness, guard, verification) sees only the sandbox.
KUBECONFIG=$KC
export KUBECONFIG
unset KUBECTL_EXTERNAL_DIFF
CTX=kind-kube-lens-dev
NS=tern-test-mutate
M=$KL_REPO/tests/integration/mutate/manifests
KL_FAILS=0

cd "$KL_REPO" || exit 1
# shellcheck source=tests/integration/mutate/harness.sh
. "$KL_REPO/tests/integration/mutate/harness.sh"

k() {
	kubectl --kubeconfig "$KC" --context "$CTX" "$@"
}

url() { # encode a value for a link parameter
	printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g'
}

reset_objects() {
	k -n "$NS" delete deployment/klm-web service/klm-web configmap/klm-config configmap/klm-a configmap/klm-b \
		--ignore-not-found --wait=true >/dev/null 2>&1
}

link() { # op kind name [extra]
	printf 'kube-lens://mutate?op=%s&kind=%s&name=%s&namespace=%s&context=%s&source=chosen%s' \
		"$1" "$2" "$3" "$NS" "$CTX" "${4:-}"
}

scenario_apply_one() {
	reset_objects
	kl_begin apply-one "kube-lens://mutate?op=apply&file=$(url "$M/one/klm-config.yaml")&context=$CTX&source=chosen"
	kl_expect phase ready
	kl_expect tier simple
	kl_expect diff "create=1 modify=0 delete=0 unknown=0"
	kl_expect segments "create:ConfigMap/klm-config"
	kl_check "nothing created by the preview" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap klm-config"
	kl_key enter
	kl_expect phase done
	kl_expect exec_status 0
	kl_check "configmap exists with LOG_LEVEL=info" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap klm-config -o jsonpath='{.data.LOG_LEVEL}')\" = info ]"
	kl_check "audit has approved+executed" sh -c "grep -q '\"decision\":\"approved\"' '$KL_W/audit.log' && grep -q '\"decision\":\"executed\"' '$KL_W/audit.log'"
}

scenario_apply_many() {
	kl_begin apply-many "kube-lens://mutate?op=apply&file=$(url "$M/many")&context=$CTX&source=chosen"
	kl_expect phase ready
	kl_expect diff "create=4 modify=0 delete=0 unknown=0"
	kl_expect_has steps "dry-run=ok"
	kl_expect_has steps "diff=changes"
	kl_key enter
	kl_expect phase done
	kl_check "deployment, service and both configmaps exist" \
		k -n "$NS" get deployment/klm-web service/klm-web configmap/klm-a configmap/klm-b
	kl_check "README.txt was not an input" sh -c "! grep -q README '$KL_W/effects.log' || ! grep -q 'README.txt [0-9a-f]' '$KL_W/transcript.luau'"
}

scenario_diff_modify_cancel() {
	work=$KL_REPO/.sandbox/mutate-it/files
	mkdir -p "$work"
	sed 's/LOG_LEVEL: info/LOG_LEVEL: debug/' "$M/one/klm-config.yaml" >"$work/klm-config.yaml"
	kl_begin diff-modify-cancel "kube-lens://mutate?op=apply&file=$(url "$work/klm-config.yaml")&context=$CTX&source=chosen"
	kl_expect phase ready
	kl_expect diff "create=0 modify=1 delete=0 unknown=0"
	kl_expect_has diff_text "-  LOG_LEVEL: info"
	kl_expect_has diff_text "+  LOG_LEVEL: debug"
	kl_key escape
	kl_expect phase closed
	kl_effects_lacks run "'exec'"
	kl_check "cancel left LOG_LEVEL=info" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap klm-config -o jsonpath='{.data.LOG_LEVEL}')\" = info ]"
	kl_check "audit records the cancel" grep -q '"decision":"cancelled"' "$KL_W/audit.log"
}

scenario_stale_file() {
	work=$KL_REPO/.sandbox/mutate-it/files
	mkdir -p "$work"
	sed 's/LOG_LEVEL: info/LOG_LEVEL: warn/' "$M/one/klm-config.yaml" >"$work/stale.yaml"
	kl_begin stale-file "kube-lens://mutate?op=apply&file=$(url "$work/stale.yaml")&context=$CTX&source=chosen"
	kl_expect phase ready
	kl_note "edit the file after the preview"
	sed 's/LOG_LEVEL: warn/LOG_LEVEL: error/' "$work/stale.yaml" >"$work/stale.yaml.tmp" && mv "$work/stale.yaml.tmp" "$work/stale.yaml"
	kl_key enter
	kl_expect phase ready
	kl_expect_has confirm_error "fingerprint mismatch"
	kl_effects_lacks run "'exec'"
	kl_check "LOG_LEVEL unchanged (info)" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap klm-config -o jsonpath='{.data.LOG_LEVEL}')\" = info ]"
	kl_key enter
	kl_expect_has confirm_error "preview again"
	kl_note "preview again, then confirm the new content"
	kl_key r r
	kl_expect_has diff_text "+  LOG_LEVEL: error"
	kl_key enter
	kl_expect phase done
	kl_check "LOG_LEVEL=error after the re-previewed apply" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap klm-config -o jsonpath='{.data.LOG_LEVEL}')\" = error ]"
}

scenario_scale() {
	kl_begin scale "$(link scale deployment klm-web '&replicas=2')"
	kl_expect phase ready
	kl_expect tier simple
	kl_expect_has view "replicas 1 → 2"
	kl_key enter
	kl_expect phase done
	kl_check "spec.replicas=2" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy klm-web -o jsonpath='{.spec.replicas}')\" = 2 ]"
	kl_key r r
	kl_expect_has view "klm-web"
}

scenario_restart() {
	before=$(k -n "$NS" get deploy klm-web -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')
	kl_begin restart "$(link restart deployment klm-web)"
	kl_expect phase ready
	kl_expect steps "targets=ok"
	kl_key enter
	kl_expect phase done
	kl_check "restartedAt annotation changed" sh -c \
		"[ -n \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy klm-web -o jsonpath='{.spec.template.metadata.annotations.kubectl\\.kubernetes\\.io/restartedAt}')\" ] && [ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy klm-web -o jsonpath='{.spec.template.metadata.annotations.kubectl\\.kubernetes\\.io/restartedAt}')\" != '$before' ]"
}

scenario_delete_typed() {
	kl_begin delete-typed "$(link delete configmap klm-a)"
	kl_expect phase ready
	kl_expect tier typed
	kl_expect token klm-a
	kl_key enter
	kl_effects_lacks run "'exec'"
	kl_type klm-
	kl_key enter
	kl_effects_lacks run "'exec'"
	kl_check "klm-a still exists after an inexact token" k -n "$NS" get configmap klm-a
	kl_type a
	kl_key enter
	kl_expect phase done
	kl_check "klm-a deleted" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap klm-a"
}

scenario_delete_cancel() {
	kl_begin delete-cancel "$(link delete configmap klm-b)"
	kl_expect tier typed
	kl_type klm-b
	kl_key escape
	kl_expect phase closed
	kl_effects_lacks run "'exec'"
	kl_check "klm-b still exists after cancel" k -n "$NS" get configmap klm-b
}

scenario_nonexistent() {
	kl_begin nonexistent "$(link delete deployment klm-nope)"
	kl_expect phase ready
	kl_expect tier blocked
	kl_expect_has steps "targets=failed"
	kl_expect_has view "NotFound"
	kl_key enter
	kl_effects_lacks run "'exec'"
}

drift_kubeconfig() { # writes $1 with contexts kl-drift-a (current) and kl-drift-b on the kind cluster
	k config view --raw --minify >"$1.base"
	server=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
	KUBECONFIG=$1.base kubectl config rename-context "$CTX" kl-drift-a >/dev/null
	KUBECONFIG=$1.base kubectl config set-context kl-drift-b --cluster="$CTX" --user="$CTX" --namespace="$NS" >/dev/null
	KUBECONFIG=$1.base kubectl config use-context kl-drift-a >/dev/null
	mv "$1.base" "$1"
	chmod 600 "$1"
	printf '%s' "$server"
}

scenario_context_drift() {
	dk=$KL_REPO/.sandbox/mutate-it/drift.kubeconfig
	drift_kubeconfig "$dk" >/dev/null
	KL_KUBECONFIG=$dk kl_begin context-drift \
		"kube-lens://mutate?op=scale&kind=deployment&name=klm-web&namespace=$NS&replicas=3"
	kl_expect context kl-drift-a
	kl_expect target_confirmation 1
	kl_key t t
	kl_note "switch current-context to kl-drift-b between preview and confirm"
	KUBECONFIG=$dk kubectl config use-context kl-drift-b >/dev/null
	kl_key enter
	kl_expect_has confirm_error "current-context changed from kl-drift-a to kl-drift-b"
	kl_effects_lacks run "'exec'"
	kl_check "replicas still 2" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy klm-web -o jsonpath='{.spec.replicas}')\" = 2 ]"
}

scenario_server_drift() {
	dk=$KL_REPO/.sandbox/mutate-it/server.kubeconfig
	drift_kubeconfig "$dk" >/dev/null
	KL_KUBECONFIG=$dk kl_begin server-drift \
		"kube-lens://mutate?op=scale&kind=deployment&name=klm-web&namespace=$NS&replicas=3&context=kl-drift-a&source=chosen"
	kl_expect phase ready
	kl_note "repoint the context's cluster at another server"
	KUBECONFIG=$dk kubectl config set-cluster "$CTX" --server=https://127.0.0.1:1 >/dev/null
	kl_key enter
	kl_expect_has confirm_error "now points to https://127.0.0.1:1"
	kl_effects_lacks run "'exec'"
}

scenario_rbac_deny_dry_run() {
	[ -f "$KL_REPO/.sandbox/rbac/kl-readonly.kubeconfig" ] || sh "$KL_REPO/tests/integration/mutate/rbac.sh" create >/dev/null
	KL_KUBECONFIG=$KL_REPO/.sandbox/rbac/kl-readonly.kubeconfig kl_begin rbac-deny-dry-run \
		"kube-lens://mutate?op=scale&kind=deployment&name=klm-web&namespace=$NS&replicas=5&context=$(url kl-readonly@kind-kube-lens-dev)&source=chosen"
	kl_expect phase ready
	kl_expect tier blocked
	kl_expect_has steps "targets=ok"
	kl_expect_has steps "dry-run=failed"
	kl_expect_has view "Forbidden"
	kl_key enter
	kl_effects_lacks run "'exec'"
	KL_KUBECONFIG=$KL_REPO/.sandbox/rbac/kl-no-delete.kubeconfig kl_begin rbac-deny-delete \
		"kube-lens://mutate?op=delete&kind=configmap&name=klm-b&namespace=$NS&context=$(url kl-no-delete@kind-kube-lens-dev)&source=chosen"
	kl_expect tier blocked
	kl_expect_has view "cannot delete resource"
}

scenario_tiny_timeout() {
	KL_PREVIEW_MS=1 kl_begin tiny-timeout "$(link scale deployment klm-web '&replicas=4')"
	kl_note "1 ms budget: every kubectl call is killed; a timed-out preview blocks"
	case $S_phase in
	error) kl_expect_has errors "timed out" ;;
	*)
		kl_expect tier blocked
		kl_expect_has steps "timeout"
		kl_expect_has reasons "blocked:preview-failed"
		;;
	esac
	kl_key enter
	kl_effects_lacks run "'exec'"
}

cronjob_manifest() { # NAME -> stdout
	printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  schedule: "0 3 * * *"\n  suspend: true\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          restartPolicy: Never\n          containers:\n            - name: report\n              image: registry.k8s.io/pause:3.10\n' \
		"$1" "$NS"
}

# The suite owns its CronJob instead of relying on the fixture world, which a
# freshly created cluster (CI) does not have.
scenario_cronjob_quick() {
	suffix=it$(date +%s | tail -c 6)
	cronjob_manifest klm-nightly | k apply -f - >/dev/null
	kl_begin cronjob-quick \
		"kube-lens://act/cronjob-run?kind=CronJob&name=klm-nightly&namespace=$NS&suffix=$suffix&context=$CTX"
	kl_expect phase ready
	kl_expect_has steps "dry-run=ok"
	kl_key enter
	kl_expect phase closed
	kl_effects_has grant
	kl_effects_has open
	kl_check "the open link carries the token" grep -q "confirm=fedcba\|confirm=[0-9a-f]\{32\}" "$KL_W/effects.log"
	kl_check "no job was created by the block" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get job klm-nightly-manual-$suffix"
	k -n "$NS" delete cronjob klm-nightly --ignore-not-found >/dev/null
}

secret_manifest() { # NAME VALUE PART_OF -> stdout
	printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    app.kubernetes.io/part-of: %s\ntype: Opaque\nstringData:\n  password: %s\n' \
		"$1" "$NS" "$3" "$2"
}

# kubectl diff masks Secret data, but the last-applied annotation (live side,
# shown as context next to any metadata change) repeats the applied
# stringData verbatim; the block must hide it unless the user opted in.
scenario_secret_redaction() {
	work=$KL_REPO/.sandbox/mutate-it/files
	mkdir -p "$work"
	k -n "$NS" delete secret klm-secret --ignore-not-found --wait=true >/dev/null 2>&1
	secret_manifest klm-secret kl-it-old-value-1 kube-lens-mutate-old | k apply -f - >/dev/null
	secret_manifest klm-secret kl-it-new-value-2 kube-lens-mutate-it >"$work/klm-secret.yaml"
	kl_begin secret-redaction "kube-lens://mutate?op=apply&file=$(url "$work/klm-secret.yaml")&context=$CTX&source=chosen"
	kl_expect phase ready
	kl_expect segments "modify:Secret/klm-secret"
	kl_expect_has diff_text "last-applied-configuration redacted by kube-lens"
	kl_expect_has diff_text "+    app.kubernetes.io/part-of: kube-lens-mutate-it"
	for v in kl-it-old-value-1 kl-it-new-value-2 a2wtaXQtb2xkLXZhbHVlLTE a2wtaXQtbmV3LXZhbHVlLTI; do
		case "$S_diff_text$S_view" in
		*"$v"*) kl_fail "secret value $v visible in the preview" ;;
		*) kl_ok "secret value $v hidden" ;;
		esac
	done
	kl_key escape
	kl_expect phase closed
	KL_SHOW_SECRETS=true kl_begin secret-shown "kube-lens://mutate?op=apply&file=$(url "$work/klm-secret.yaml")&context=$CTX&source=chosen"
	kl_expect_has diff_text "kl-it-old-value-1"
	kl_key escape
	kl_check "cancel left the old value" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get secret klm-secret -o jsonpath='{.data.password}' | base64 -d)\" = kl-it-old-value-1 ]"
	k -n "$NS" delete secret klm-secret --ignore-not-found --wait=true >/dev/null 2>&1
}

# The palette's apply link carries only the pane's cwd; the block asks for the
# path, resolves it against that cwd and previews before anything runs.
scenario_apply_prompt() {
	reset_objects
	kl_begin apply-prompt "kube-lens://mutate?op=apply&cwd=$(url "$M")&context=$CTX&source=chosen"
	kl_expect phase input
	kl_effects_lacks run
	kl_type many
	kl_key enter
	kl_expect phase ready
	kl_expect_has command "-f $M/many"
	kl_expect diff "create=4 modify=0 delete=0 unknown=0"
	kl_check "the preview created nothing" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap klm-a"
	kl_key enter
	kl_expect phase done
	kl_expect exec_status 0
	kl_check "deployment, service and both configmaps exist" \
		k -n "$NS" get deployment/klm-web service/klm-web configmap/klm-a configmap/klm-b
}

# mutations.enabled=false: a guarded command is refused by the block with a
# reason the guard prints; nothing runs.
scenario_guard_disabled() {
	fake=$KL_REPO/.sandbox/mutate-it/bin/tern
	mkdir -p "$(dirname "$fake")"
	guard_fake_tern "$fake"
	printf '\n== guard-disabled\n'
	KL_W=$KL_REPO/.sandbox/mutate-it/guard-disabled
	mkdir -p "$KL_W"
	: >"$KL_W/evidence.log"
	before=$(k -n "$NS" get deploy klm-web -o jsonpath='{.spec.replicas}')
	out=$(env TERM_PROGRAM=tern TERN_PANE=7 KUBE_LENS_SPOOL="$KL_SPOOL" TERN_BIN="$fake" KL_REPO="$KL_REPO" \
		KUBECONFIG="$KC" KUBE_LENS_GUARD_TIMEOUT=120 KL_MUTATIONS_ENABLED=false KL_GUARD_NAME=guard-disabled-block \
		KL_GUARD_DECISION=none sh "$KL_REPO/shell/kube-lens-guard" kubectl --context "$CTX" -n "$NS" scale deploy/klm-web --replicas=4 2>&1)
	st=$?
	kl_log "guard disabled: rc=$st $out"
	printf '    guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	if [ $st = 1 ]; then kl_ok "guard exits 1"; else kl_fail "guard rc=$st, want 1"; fi
	case $out in
	*"denied in Tern: "*isabled*) kl_ok "the guard prints the block's reason" ;;
	*) kl_fail "no disabled reason in the guard output" ;;
	esac
	kl_check "replicas unchanged ($before)" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy klm-web -o jsonpath='{.spec.replicas}')\" = '$before' ]"
}

guard_fake_tern() { # writes a fake `tern` whose `open --wait REQ` runs the headless block
	cat >"$1" <<'EOF'
#!/bin/sh
# Fake `tern open --wait <req>`: plays the approve block headlessly, approving
# (KL_GUARD_DECISION=approve, typing the token when asked) or denying.
[ "$1" = open ] && [ "$2" = --wait ] || exit 2
KL_FAILS=0
. "$KL_REPO/tests/integration/mutate/harness.sh"
KL_REQUEST=$3 KL_PANES="\"$TERN_PANE\"" kl_begin "$KL_GUARD_NAME" "$3" >>"$KL_REPO/.sandbox/mutate-it/guard.out"
[ -n "${KL_GUARD_EDIT:-}" ] && sh -c "$KL_GUARD_EDIT"
case ${KL_GUARD_DECISION:-approve} in
approve)
	[ -n "$S_token" ] && kl_type "$S_token" >>"$KL_REPO/.sandbox/mutate-it/guard.out"
	[ "$S_target_confirmation" = 1 ] && kl_key t t >>"$KL_REPO/.sandbox/mutate-it/guard.out"
	kl_key enter >>"$KL_REPO/.sandbox/mutate-it/guard.out"
	;;
none) ;;
*) kl_key escape >>"$KL_REPO/.sandbox/mutate-it/guard.out" ;;
esac
[ -n "${KL_GUARD_EDIT_AFTER:-}" ] && sh -c "$KL_GUARD_EDIT_AFTER"
exit 0
EOF
	chmod +x "$1"
}

scenario_guard_roundtrip() {
	fake=$KL_REPO/.sandbox/mutate-it/bin/tern
	mkdir -p "$(dirname "$fake")"
	guard_fake_tern "$fake"
	: >"$KL_REPO/.sandbox/mutate-it/guard.out"
	guard() {
		env TERM_PROGRAM=tern TERN_PANE=7 KUBE_LENS_SPOOL="$KL_SPOOL" TERN_BIN="$fake" KL_REPO="$KL_REPO" \
			KUBECONFIG="$KC" KUBE_LENS_GUARD_TIMEOUT=120 sh "$KL_REPO/shell/kube-lens-guard" kubectl "$@"
	}
	printf '\n== guard-roundtrip\n'
	KL_W=$KL_REPO/.sandbox/mutate-it/guard
	mkdir -p "$KL_W"
	: >"$KL_W/evidence.log"
	out=$(KL_GUARD_NAME=guard-approve KL_GUARD_DECISION=approve guard --context "$CTX" -n "$NS" scale deploy/klm-web --replicas=1 2>&1)
	st=$?
	kl_log "guard approve: rc=$st $out"
	printf '    guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	if [ $st = 0 ]; then kl_ok "guard executed after approval"; else kl_fail "guard approve rc=$st"; fi
	kl_check "replicas=1 after the guarded scale" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy klm-web -o jsonpath='{.spec.replicas}')\" = 1 ]"

	out=$(KL_GUARD_NAME=guard-deny KL_GUARD_DECISION=deny guard --context "$CTX" -n "$NS" delete configmap klm-b 2>&1)
	st=$?
	kl_log "guard deny: rc=$st $out"
	printf '    guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	case $out in *denied*) kl_ok "denied in Tern" ;; *) kl_fail "deny not reported" ;; esac
	kl_check "klm-b survives the denial" k -n "$NS" get configmap klm-b

	work=$KL_REPO/.sandbox/mutate-it/files
	mkdir -p "$work"
	sed 's/LOG_LEVEL: info/LOG_LEVEL: trace/' "$M/one/klm-config.yaml" >"$work/guard.yaml"
	out=$(cd "$work" && KL_GUARD_NAME=guard-stale-block KL_GUARD_DECISION=approve \
		KL_GUARD_EDIT="sed 's/trace/fatal/' '$work/guard.yaml' >'$work/guard.yaml.tmp' && mv '$work/guard.yaml.tmp' '$work/guard.yaml'" guard --context "$CTX" apply -f guard.yaml 2>&1)
	st=$?
	kl_log "guard stale (edited before approval): rc=$st $out"
	printf '    edited before approval: guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	if [ $st != 0 ]; then kl_ok "block refused to approve the edited file (rc=$st)"; else kl_fail "edited file was applied"; fi
	grep -q "fingerprint mismatch" "$KL_REPO/.sandbox/mutate-it/guard-stale-block/evidence.log" &&
		kl_ok "the block reported the fingerprint mismatch" || kl_fail "no block refusal recorded"

	sed 's/LOG_LEVEL: info/LOG_LEVEL: trace/' "$M/one/klm-config.yaml" >"$work/guard.yaml"
	out=$(cd "$work" && KL_GUARD_NAME=guard-stale-shell KL_GUARD_DECISION=approve \
		KL_GUARD_EDIT_AFTER="sed 's/trace/fatal/' '$work/guard.yaml' >'$work/guard.yaml.tmp' && mv '$work/guard.yaml.tmp' '$work/guard.yaml'" guard --context "$CTX" apply -f guard.yaml 2>&1)
	st=$?
	kl_log "guard stale (edited after approval): rc=$st $out"
	printf '    edited after approval: guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	case $out in
	*"fingerprint mismatch"*) kl_ok "the guard refused the approved-then-edited file" ;;
	*) kl_fail "guard did not report a fingerprint mismatch" ;;
	esac
	kl_check "LOG_LEVEL never became fatal" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap klm-config -o jsonpath='{.data.LOG_LEVEL}')\" != fatal ]"
	ls -la "$KL_SPOOL" >>"$KL_W/evidence.log"
}

ALL="apply_one apply_many diff_modify_cancel stale_file scale restart delete_typed delete_cancel nonexistent
context_drift server_drift rbac_deny_dry_run tiny_timeout cronjob_quick guard_roundtrip secret_redaction apply_prompt
guard_disabled"

for s in ${*:-$ALL}; do
	"scenario_$s"
done

printf '\n%s failure(s)\n' "$KL_FAILS"
[ "$KL_FAILS" = 0 ]

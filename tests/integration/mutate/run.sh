#!/bin/sh
# Mutation integration scenarios against the kind cluster: the approve
# block's pure session driven by harness.sh with real kubectl results.
# Everything targets context kind-tern-kube-dev through .sandbox kubeconfigs
# and only namespace tern-test-mutate. Evidence per scenario lands in
# .sandbox/mutate-it/<scenario>/{evidence.log,view.txt,effects.log,audit.log}.
#
#   tests/integration/mutate/run.sh [SCENARIO...]   (default: all)
set -u

TK_REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
export TK_REPO
KC=$(sh "$TK_REPO/scripts/cluster.sh" kubeconfig-path) || exit 1
# Every process below (harness, guard, verification) sees only the sandbox.
KUBECONFIG=$KC
export KUBECONFIG
unset KUBECTL_EXTERNAL_DIFF
CTX=kind-tern-kube-dev
NS=tern-test-mutate
M=$TK_REPO/tests/integration/mutate/manifests
TK_FAILS=0

cd "$TK_REPO" || exit 1
# shellcheck source=tests/integration/mutate/harness.sh
. "$TK_REPO/tests/integration/mutate/harness.sh"

k() {
	kubectl --kubeconfig "$KC" --context "$CTX" "$@"
}

url() { # encode a value for a link parameter
	printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g'
}

reset_objects() {
	k -n "$NS" delete deployment/tkm-web service/tkm-web configmap/tkm-config configmap/tkm-a configmap/tkm-b \
		--ignore-not-found --wait=true >/dev/null 2>&1
}

link() { # op kind name [extra]
	printf 'tern-kube://mutate?op=%s&kind=%s&name=%s&namespace=%s&context=%s&source=chosen%s' \
		"$1" "$2" "$3" "$NS" "$CTX" "${4:-}"
}

scenario_apply_one() {
	reset_objects
	tk_begin apply-one "tern-kube://mutate?op=apply&file=$(url "$M/one/tkm-config.yaml")&context=$CTX&source=chosen"
	tk_expect phase ready
	tk_expect tier simple
	tk_expect diff "create=1 modify=0 delete=0 unknown=0"
	tk_expect segments "create:ConfigMap/tkm-config"
	tk_check "nothing created by the preview" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-config"
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	tk_check "configmap exists with LOG_LEVEL=info" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-config -o jsonpath='{.data.LOG_LEVEL}')\" = info ]"
	tk_check "audit has approved+executed" sh -c "grep -q '\"decision\":\"approved\"' '$TK_W/audit.log' && grep -q '\"decision\":\"executed\"' '$TK_W/audit.log'"
}

scenario_apply_many() {
	tk_begin apply-many "tern-kube://mutate?op=apply&file=$(url "$M/many")&context=$CTX&source=chosen"
	tk_expect phase ready
	tk_expect diff "create=4 modify=0 delete=0 unknown=0"
	tk_expect_has steps "dry-run=ok"
	tk_expect_has steps "diff=changes"
	tk_key enter
	tk_expect phase done
	tk_check "deployment, service and both configmaps exist" \
		k -n "$NS" get deployment/tkm-web service/tkm-web configmap/tkm-a configmap/tkm-b
	tk_check "README.txt was not an input" sh -c "! grep -q README '$TK_W/effects.log' || ! grep -q 'README.txt [0-9a-f]' '$TK_W/transcript.luau'"
}

scenario_diff_modify_cancel() {
	work=$TK_REPO/.sandbox/mutate-it/files
	mkdir -p "$work"
	sed 's/LOG_LEVEL: info/LOG_LEVEL: debug/' "$M/one/tkm-config.yaml" >"$work/tkm-config.yaml"
	tk_begin diff-modify-cancel "tern-kube://mutate?op=apply&file=$(url "$work/tkm-config.yaml")&context=$CTX&source=chosen"
	tk_expect phase ready
	tk_expect diff "create=0 modify=1 delete=0 unknown=0"
	tk_expect_has diff_text "-  LOG_LEVEL: info"
	tk_expect_has diff_text "+  LOG_LEVEL: debug"
	tk_key escape
	tk_expect phase closed
	tk_effects_lacks run "'exec'"
	tk_check "cancel left LOG_LEVEL=info" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-config -o jsonpath='{.data.LOG_LEVEL}')\" = info ]"
	tk_check "audit records the cancel" grep -q '"decision":"cancelled"' "$TK_W/audit.log"
}

scenario_stale_file() {
	work=$TK_REPO/.sandbox/mutate-it/files
	mkdir -p "$work"
	sed 's/LOG_LEVEL: info/LOG_LEVEL: warn/' "$M/one/tkm-config.yaml" >"$work/stale.yaml"
	tk_begin stale-file "tern-kube://mutate?op=apply&file=$(url "$work/stale.yaml")&context=$CTX&source=chosen"
	tk_expect phase ready
	tk_note "edit the file after the preview"
	sed 's/LOG_LEVEL: warn/LOG_LEVEL: error/' "$work/stale.yaml" >"$work/stale.yaml.tmp" && mv "$work/stale.yaml.tmp" "$work/stale.yaml"
	tk_key enter
	tk_expect phase ready
	tk_expect_has confirm_error "fingerprint mismatch"
	tk_effects_lacks run "'exec'"
	tk_check "LOG_LEVEL unchanged (info)" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-config -o jsonpath='{.data.LOG_LEVEL}')\" = info ]"
	tk_key enter
	tk_expect_has confirm_error "preview again"
	tk_note "preview again, then confirm the new content"
	tk_key r r
	tk_expect_has diff_text "+  LOG_LEVEL: error"
	tk_key enter
	tk_expect phase done
	tk_check "LOG_LEVEL=error after the re-previewed apply" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-config -o jsonpath='{.data.LOG_LEVEL}')\" = error ]"
}

scenario_scale() {
	tk_begin scale "$(link scale deployment tkm-web '&replicas=2')"
	tk_expect phase ready
	tk_expect tier simple
	tk_expect_has view "replicas 1 → 2"
	tk_key enter
	tk_expect phase done
	tk_check "spec.replicas=2" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy tkm-web -o jsonpath='{.spec.replicas}')\" = 2 ]"
	tk_key r r
	tk_expect_has view "tkm-web"
}

scenario_restart() {
	before=$(k -n "$NS" get deploy tkm-web -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')
	tk_begin restart "$(link restart deployment tkm-web)"
	tk_expect phase ready
	tk_expect steps "targets=ok"
	tk_key enter
	tk_expect phase done
	tk_check "restartedAt annotation changed" sh -c \
		"[ -n \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy tkm-web -o jsonpath='{.spec.template.metadata.annotations.kubectl\\.kubernetes\\.io/restartedAt}')\" ] && [ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy tkm-web -o jsonpath='{.spec.template.metadata.annotations.kubectl\\.kubernetes\\.io/restartedAt}')\" != '$before' ]"
}

scenario_delete_typed() {
	tk_begin delete-typed "$(link delete configmap tkm-a)"
	tk_expect phase ready
	tk_expect tier typed
	tk_expect token tkm-a
	tk_key enter
	tk_effects_lacks run "'exec'"
	tk_type tkm-
	tk_key enter
	tk_effects_lacks run "'exec'"
	tk_check "tkm-a still exists after an inexact token" k -n "$NS" get configmap tkm-a
	tk_type a
	tk_key enter
	tk_expect phase done
	tk_check "tkm-a deleted" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-a"
}

scenario_delete_cancel() {
	tk_begin delete-cancel "$(link delete configmap tkm-b)"
	tk_expect tier typed
	tk_type tkm-b
	tk_key escape
	tk_expect phase closed
	tk_effects_lacks run "'exec'"
	tk_check "tkm-b still exists after cancel" k -n "$NS" get configmap tkm-b
}

scenario_nonexistent() {
	tk_begin nonexistent "$(link delete deployment tkm-nope)"
	tk_expect phase ready
	tk_expect tier blocked
	tk_expect_has steps "targets=failed"
	tk_expect_has view "NotFound"
	tk_key enter
	tk_effects_lacks run "'exec'"
}

drift_kubeconfig() { # writes $1 with contexts tk-drift-a (current) and tk-drift-b on the kind cluster
	k config view --raw --minify >"$1.base"
	server=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
	KUBECONFIG=$1.base kubectl config rename-context "$CTX" tk-drift-a >/dev/null
	KUBECONFIG=$1.base kubectl config set-context tk-drift-b --cluster="$CTX" --user="$CTX" --namespace="$NS" >/dev/null
	KUBECONFIG=$1.base kubectl config use-context tk-drift-a >/dev/null
	mv "$1.base" "$1"
	chmod 600 "$1"
	printf '%s' "$server"
}

scenario_context_drift() {
	dk=$TK_REPO/.sandbox/mutate-it/drift.kubeconfig
	drift_kubeconfig "$dk" >/dev/null
	TK_KUBECONFIG=$dk tk_begin context-drift \
		"tern-kube://mutate?op=scale&kind=deployment&name=tkm-web&namespace=$NS&replicas=3"
	tk_expect context tk-drift-a
	tk_expect target_confirmation 1
	tk_key t t
	tk_note "switch current-context to tk-drift-b between preview and confirm"
	KUBECONFIG=$dk kubectl config use-context tk-drift-b >/dev/null
	tk_key enter
	tk_expect_has confirm_error "current-context changed from tk-drift-a to tk-drift-b"
	tk_effects_lacks run "'exec'"
	tk_check "replicas still 2" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy tkm-web -o jsonpath='{.spec.replicas}')\" = 2 ]"
}

scenario_server_drift() {
	dk=$TK_REPO/.sandbox/mutate-it/server.kubeconfig
	drift_kubeconfig "$dk" >/dev/null
	TK_KUBECONFIG=$dk tk_begin server-drift \
		"tern-kube://mutate?op=scale&kind=deployment&name=tkm-web&namespace=$NS&replicas=3&context=tk-drift-a&source=chosen"
	tk_expect phase ready
	tk_note "repoint the context's cluster at another server"
	KUBECONFIG=$dk kubectl config set-cluster "$CTX" --server=https://127.0.0.1:1 >/dev/null
	tk_key enter
	tk_expect_has confirm_error "now points to https://127.0.0.1:1"
	tk_effects_lacks run "'exec'"
}

scenario_rbac_deny_dry_run() {
	[ -f "$TK_REPO/.sandbox/rbac/tk-readonly.kubeconfig" ] || sh "$TK_REPO/tests/integration/mutate/rbac.sh" create >/dev/null
	TK_KUBECONFIG=$TK_REPO/.sandbox/rbac/tk-readonly.kubeconfig tk_begin rbac-deny-dry-run \
		"tern-kube://mutate?op=scale&kind=deployment&name=tkm-web&namespace=$NS&replicas=5&context=$(url tk-readonly@kind-tern-kube-dev)&source=chosen"
	tk_expect phase ready
	tk_expect tier blocked
	tk_expect_has steps "targets=ok"
	tk_expect_has steps "dry-run=failed"
	tk_expect_has view "Forbidden"
	tk_key enter
	tk_effects_lacks run "'exec'"
	TK_KUBECONFIG=$TK_REPO/.sandbox/rbac/tk-no-delete.kubeconfig tk_begin rbac-deny-delete \
		"tern-kube://mutate?op=delete&kind=configmap&name=tkm-b&namespace=$NS&context=$(url tk-no-delete@kind-tern-kube-dev)&source=chosen"
	tk_expect tier blocked
	tk_expect_has view "cannot delete resource"
}

scenario_tiny_timeout() {
	TK_PREVIEW_MS=1 tk_begin tiny-timeout "$(link scale deployment tkm-web '&replicas=4')"
	tk_note "1 ms budget: every kubectl call is killed; a timed-out preview blocks"
	case $S_phase in
	error) tk_expect_has errors "timed out" ;;
	*)
		tk_expect tier blocked
		tk_expect_has steps "timeout"
		tk_expect_has reasons "blocked:preview-failed"
		;;
	esac
	tk_key enter
	tk_effects_lacks run "'exec'"
}

cronjob_manifest() { # NAME -> stdout
	printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  schedule: "0 3 * * *"\n  suspend: true\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          restartPolicy: Never\n          containers:\n            - name: report\n              image: registry.k8s.io/pause:3.10\n' \
		"$1" "$NS"
}

# The suite owns its CronJob instead of relying on the fixture world, which a
# freshly created cluster (CI) does not have.
scenario_cronjob_quick() {
	suffix=it$(date +%s | tail -c 6)
	cronjob_manifest tkm-nightly | k apply -f - >/dev/null
	tk_begin cronjob-quick \
		"tern-kube://act/cronjob-run?kind=CronJob&name=tkm-nightly&namespace=$NS&suffix=$suffix&context=$CTX"
	tk_expect phase ready
	tk_expect_has steps "dry-run=ok"
	tk_key enter
	tk_expect phase closed
	tk_effects_has grant
	tk_effects_has open
	tk_check "the open link carries the token" grep -q "confirm=fedcba\|confirm=[0-9a-f]\{32\}" "$TK_W/effects.log"
	tk_check "no job was created by the block" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get job tkm-nightly-manual-$suffix"
	k -n "$NS" delete cronjob tkm-nightly --ignore-not-found >/dev/null
}

secret_manifest() { # NAME VALUE PART_OF -> stdout
	printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    app.kubernetes.io/part-of: %s\ntype: Opaque\nstringData:\n  password: %s\n' \
		"$1" "$NS" "$3" "$2"
}

# kubectl diff masks Secret data, but the last-applied annotation (live side,
# shown as context next to any metadata change) repeats the applied
# stringData verbatim; the block must hide it unless the user opted in.
scenario_secret_redaction() {
	work=$TK_REPO/.sandbox/mutate-it/files
	mkdir -p "$work"
	k -n "$NS" delete secret tkm-secret --ignore-not-found --wait=true >/dev/null 2>&1
	secret_manifest tkm-secret tk-it-old-value-1 tern-kube-mutate-old | k apply -f - >/dev/null
	secret_manifest tkm-secret tk-it-new-value-2 tern-kube-mutate-it >"$work/tkm-secret.yaml"
	tk_begin secret-redaction "tern-kube://mutate?op=apply&file=$(url "$work/tkm-secret.yaml")&context=$CTX&source=chosen"
	tk_expect phase ready
	tk_expect segments "modify:Secret/tkm-secret"
	tk_expect_has diff_text "last-applied-configuration redacted by tern-kube"
	tk_expect_has diff_text "+    app.kubernetes.io/part-of: tern-kube-mutate-it"
	for v in tk-it-old-value-1 tk-it-new-value-2 a2wtaXQtb2xkLXZhbHVlLTE a2wtaXQtbmV3LXZhbHVlLTI; do
		case "$S_diff_text$S_view" in
		*"$v"*) tk_fail "secret value $v visible in the preview" ;;
		*) tk_ok "secret value $v hidden" ;;
		esac
	done
	tk_key escape
	tk_expect phase closed
	TK_SHOW_SECRETS=true tk_begin secret-shown "tern-kube://mutate?op=apply&file=$(url "$work/tkm-secret.yaml")&context=$CTX&source=chosen"
	tk_expect_has diff_text "tk-it-old-value-1"
	tk_key escape
	tk_check "cancel left the old value" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get secret tkm-secret -o jsonpath='{.data.password}' | base64 -d)\" = tk-it-old-value-1 ]"
	k -n "$NS" delete secret tkm-secret --ignore-not-found --wait=true >/dev/null 2>&1
}

# The palette's apply link carries only the pane's cwd; the block asks for the
# path, resolves it against that cwd and previews before anything runs.
scenario_apply_prompt() {
	reset_objects
	tk_begin apply-prompt "tern-kube://mutate?op=apply&cwd=$(url "$M")&context=$CTX&source=chosen"
	tk_expect phase input
	tk_effects_lacks run
	tk_type many
	tk_key enter
	tk_expect phase ready
	tk_expect_has command "-f $M/many"
	tk_expect diff "create=4 modify=0 delete=0 unknown=0"
	tk_check "the preview created nothing" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-a"
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	tk_check "deployment, service and both configmaps exist" \
		k -n "$NS" get deployment/tkm-web service/tkm-web configmap/tkm-a configmap/tkm-b
}

# mutations.enabled=false: a guarded command is refused by the block with a
# reason the guard prints; nothing runs.
scenario_guard_disabled() {
	fake=$TK_REPO/.sandbox/mutate-it/bin/tern
	mkdir -p "$(dirname "$fake")"
	guard_fake_tern "$fake"
	printf '\n== guard-disabled\n'
	TK_W=$TK_REPO/.sandbox/mutate-it/guard-disabled
	mkdir -p "$TK_W"
	: >"$TK_W/evidence.log"
	before=$(k -n "$NS" get deploy tkm-web -o jsonpath='{.spec.replicas}')
	out=$(env TERM_PROGRAM=tern TERN_PANE=7 TKUBE_SPOOL="$TK_SPOOL" TERN_BIN="$fake" TK_REPO="$TK_REPO" \
		KUBECONFIG="$KC" TKUBE_GUARD_TIMEOUT=120 TK_MUTATIONS_ENABLED=false TK_GUARD_NAME=guard-disabled-block \
		TK_GUARD_DECISION=none sh "$TK_REPO/shell/tern-kube-guard" kubectl --context "$CTX" -n "$NS" scale deploy/tkm-web --replicas=4 2>&1)
	st=$?
	tk_log "guard disabled: rc=$st $out"
	printf '    guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	if [ $st = 1 ]; then tk_ok "guard exits 1"; else tk_fail "guard rc=$st, want 1"; fi
	case $out in
	*"denied in Tern: "*isabled*) tk_ok "the guard prints the block's reason" ;;
	*) tk_fail "no disabled reason in the guard output" ;;
	esac
	tk_check "replicas unchanged ($before)" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy tkm-web -o jsonpath='{.spec.replicas}')\" = '$before' ]"
}

guard_fake_tern() { # writes a fake `tern` whose `open --wait REQ` runs the headless block
	cat >"$1" <<'EOF'
#!/bin/sh
# Fake `tern open --wait <req>`: plays the approve block headlessly, approving
# (TK_GUARD_DECISION=approve, typing the token when asked) or denying.
[ "$1" = open ] && [ "$2" = --wait ] || exit 2
TK_FAILS=0
. "$TK_REPO/tests/integration/mutate/harness.sh"
TK_REQUEST=$3 TK_PANES="\"$TERN_PANE\"" tk_begin "$TK_GUARD_NAME" "$3" >>"$TK_REPO/.sandbox/mutate-it/guard.out"
[ -n "${TK_GUARD_EDIT:-}" ] && sh -c "$TK_GUARD_EDIT"
case ${TK_GUARD_DECISION:-approve} in
approve)
	[ -n "$S_token" ] && tk_type "$S_token" >>"$TK_REPO/.sandbox/mutate-it/guard.out"
	[ "$S_target_confirmation" = 1 ] && tk_key t t >>"$TK_REPO/.sandbox/mutate-it/guard.out"
	tk_key enter >>"$TK_REPO/.sandbox/mutate-it/guard.out"
	;;
none) ;;
*) tk_key escape >>"$TK_REPO/.sandbox/mutate-it/guard.out" ;;
esac
[ -n "${TK_GUARD_EDIT_AFTER:-}" ] && sh -c "$TK_GUARD_EDIT_AFTER"
exit 0
EOF
	chmod +x "$1"
}

scenario_guard_roundtrip() {
	fake=$TK_REPO/.sandbox/mutate-it/bin/tern
	mkdir -p "$(dirname "$fake")"
	guard_fake_tern "$fake"
	: >"$TK_REPO/.sandbox/mutate-it/guard.out"
	guard() {
		env TERM_PROGRAM=tern TERN_PANE=7 TKUBE_SPOOL="$TK_SPOOL" TERN_BIN="$fake" TK_REPO="$TK_REPO" \
			KUBECONFIG="$KC" TKUBE_GUARD_TIMEOUT=120 sh "$TK_REPO/shell/tern-kube-guard" kubectl "$@"
	}
	printf '\n== guard-roundtrip\n'
	TK_W=$TK_REPO/.sandbox/mutate-it/guard
	mkdir -p "$TK_W"
	: >"$TK_W/evidence.log"
	out=$(TK_GUARD_NAME=guard-approve TK_GUARD_DECISION=approve guard --context "$CTX" -n "$NS" scale deploy/tkm-web --replicas=1 2>&1)
	st=$?
	tk_log "guard approve: rc=$st $out"
	printf '    guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	if [ $st = 0 ]; then tk_ok "guard executed after approval"; else tk_fail "guard approve rc=$st"; fi
	tk_check "replicas=1 after the guarded scale" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get deploy tkm-web -o jsonpath='{.spec.replicas}')\" = 1 ]"

	out=$(TK_GUARD_NAME=guard-deny TK_GUARD_DECISION=deny guard --context "$CTX" -n "$NS" delete configmap tkm-b 2>&1)
	st=$?
	tk_log "guard deny: rc=$st $out"
	printf '    guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	case $out in *denied*) tk_ok "denied in Tern" ;; *) tk_fail "deny not reported" ;; esac
	tk_check "tkm-b survives the denial" k -n "$NS" get configmap tkm-b

	work=$TK_REPO/.sandbox/mutate-it/files
	mkdir -p "$work"
	sed 's/LOG_LEVEL: info/LOG_LEVEL: trace/' "$M/one/tkm-config.yaml" >"$work/guard.yaml"
	out=$(cd "$work" && TK_GUARD_NAME=guard-stale-block TK_GUARD_DECISION=approve \
		TK_GUARD_EDIT="sed 's/trace/fatal/' '$work/guard.yaml' >'$work/guard.yaml.tmp' && mv '$work/guard.yaml.tmp' '$work/guard.yaml'" guard --context "$CTX" apply -f guard.yaml 2>&1)
	st=$?
	tk_log "guard stale (edited before approval): rc=$st $out"
	printf '    edited before approval: guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	if [ $st != 0 ]; then tk_ok "block refused to approve the edited file (rc=$st)"; else tk_fail "edited file was applied"; fi
	grep -q "fingerprint mismatch" "$TK_REPO/.sandbox/mutate-it/guard-stale-block/evidence.log" &&
		tk_ok "the block reported the fingerprint mismatch" || tk_fail "no block refusal recorded"

	sed 's/LOG_LEVEL: info/LOG_LEVEL: trace/' "$M/one/tkm-config.yaml" >"$work/guard.yaml"
	out=$(cd "$work" && TK_GUARD_NAME=guard-stale-shell TK_GUARD_DECISION=approve \
		TK_GUARD_EDIT_AFTER="sed 's/trace/fatal/' '$work/guard.yaml' >'$work/guard.yaml.tmp' && mv '$work/guard.yaml.tmp' '$work/guard.yaml'" guard --context "$CTX" apply -f guard.yaml 2>&1)
	st=$?
	tk_log "guard stale (edited after approval): rc=$st $out"
	printf '    edited after approval: guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	case $out in
	*"fingerprint mismatch"*) tk_ok "the guard refused the approved-then-edited file" ;;
	*) tk_fail "guard did not report a fingerprint mismatch" ;;
	esac
	tk_check "LOG_LEVEL never became fatal" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-config -o jsonpath='{.data.LOG_LEVEL}')\" != fatal ]"
	ls -la "$TK_SPOOL" >>"$TK_W/evidence.log"
}

ALL="apply_one apply_many diff_modify_cancel stale_file scale restart delete_typed delete_cancel nonexistent
context_drift server_drift rbac_deny_dry_run tiny_timeout cronjob_quick guard_roundtrip secret_redaction apply_prompt
guard_disabled"

for s in ${*:-$ALL}; do
	"scenario_$s"
done

printf '\n%s failure(s)\n' "$TK_FAILS"
[ "$TK_FAILS" = 0 ]

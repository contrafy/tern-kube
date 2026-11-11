#!/bin/sh
# Mutation integration scenarios against the kind cluster: the approve
# block's pure session driven by harness.sh with real kubectl (and, for the
# helm_* scenarios, .tools/bin/helm) results. Everything targets context
# kind-tern-kube-dev through .sandbox kubeconfigs and only namespaces
# tern-test-mutate and tern-test-helm-it. Evidence per scenario lands in
# .sandbox/mutate-it/<scenario>/{evidence.log,view.txt,effects.log,audit.log}.
# TK_IT_HELM overrides the helm program of the helm_* scenarios (also the
# approve block's, through TK_HELM; CI runs them with Helm 3 and Helm 4) and
# TK_IT_HELM_NS their namespace.
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
# freshly created cluster (CI) does not have. After the block confirms, the
# split the window would open (splitline.luau) runs here against the real
# guard core: its outcome record carries the approved record's run id.
scenario_cronjob_quick() {
	suffix=it$(date +%s | tail -c 6)
	cronjob_manifest tkm-nightly | k apply -f - >/dev/null
	grant=0123456789abcdef0123456789abcdef
	run=fedcba98765432100123456789abcdef
	TK_GRANT=$grant
	TK_RUN=$run
	tk_begin cronjob-quick \
		"tern-kube://act/cronjob-run?kind=CronJob&name=tkm-nightly&namespace=$NS&suffix=$suffix&context=$CTX"
	TK_GRANT=
	TK_RUN=
	tk_expect phase ready
	tk_expect_has steps "dry-run=ok"
	tk_key enter
	# The block stays open to show the Job it asked the window to create.
	tk_expect phase done
	tk_effects_lacks grant
	tk_effects_has open
	tk_check "the open link carries the window's token" grep -q "confirm=$grant" "$TK_W/effects.log"
	tk_check "no job was created by the block" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get job tkm-nightly-manual-$suffix"
	tk_check "the approval is logged as quick with the run id" \
		grep -q "\"decision\":\"approved\",\"mode\":\"quick\",\"run\":\"$run\"" "$TK_W/audit.log"
	tk_check "the grant token is not in the audit log" sh -c "! grep -q $grant '$TK_W/audit.log'"

	opened=$(sed -n 's/^open //p' "$TK_W/effects.log" | head -n 1)
	line=$("$TK_LUAU" "$TK_REPO/tests/integration/mutate/splitline.luau" -a "$opened" "$TK_REPO/shell/tern-kube-guard" "$run")
	log=${TK_SPOOL%/*}/audit.log
	rm -f "$log"
	out=$(TKUBE_SPOOL=$TK_SPOOL sh -c "$line" 2>&1 </dev/null)
	st=$?
	tk_log "split: rc=$st $out"
	if [ "$st" = 0 ]; then tk_ok "the split created the job (rc=0)"; else tk_fail "split rc=$st: $out"; fi
	tk_check "job tkm-nightly-manual-$suffix exists" k -n "$NS" get job "tkm-nightly-manual-$suffix"
	tk_check "the split recorded the outcome with the same run id" \
		grep -q "\"decision\":\"executed\",\"mode\":\"quick\",\"run\":\"$run\",\"op\":\"create job\",\"family\":\"cronjob-run\"" "$log"
	tk_check "the outcome names the job" grep -q "\"objects\":\\[\"Job $NS/tkm-nightly-manual-$suffix\"\\]" "$log"
	cat "$log" >>"$TK_W/audit.log" 2>/dev/null

	out=$(TKUBE_SPOOL=$TK_SPOOL sh -c "$line" 2>&1 </dev/null)
	st=$?
	tk_log "split again: rc=$st $out"
	if [ "$st" != 0 ]; then tk_ok "a second create fails (rc=$st)"; else tk_fail "the job was created twice"; fi
	tk_check "the failure is recorded" grep -q "\"decision\":\"failed\",\"mode\":\"quick\",\"run\":\"$run\"" "$log"
	rm -f "$log"
	k -n "$NS" delete job "tkm-nightly-manual-$suffix" --ignore-not-found >/dev/null
	k -n "$NS" delete cronjob tkm-nightly --ignore-not-found >/dev/null
}

# An approve block from an older window half gets no token: it must refuse
# before previewing anything.
scenario_cronjob_quick_no_token() {
	tk_begin cronjob-quick-no-token \
		"tern-kube://act/cronjob-run?kind=CronJob&name=tkm-nightly&namespace=$NS&suffix=x1&context=$CTX"
	tk_expect phase error
	tk_expect_has errors "without a confirmation token"
	tk_effects_lacks run
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

# MUT-F1: a command without -n runs in the context's namespace, which kubens
# rewrites in place (same context name, same request fingerprint). A switch
# after the preview is refused by the block at approval; a switch after the
# approval by the guard right before kubectl runs. An approval that holds
# runs in the previewed namespace and its outcome reaches the audit log.
scenario_guard_namespace_bound() {
	fake=$TK_REPO/.sandbox/mutate-it/bin/tern
	mkdir -p "$(dirname "$fake")" "$TK_REPO/.sandbox/mutate-it/files"
	guard_fake_tern "$fake"
	printf '\n== guard-namespace-bound\n'
	TK_W=$TK_REPO/.sandbox/mutate-it/guard-namespace
	mkdir -p "$TK_W"
	: >"$TK_W/evidence.log"
	kc=$TK_REPO/.sandbox/mutate-it/files/kubeconfig-ns
	cp "$KC" "$kc"
	cluster=$(kubectl --kubeconfig "$kc" config view -o "jsonpath={.contexts[?(@.name==\"$CTX\")].context.cluster}")
	user=$(kubectl --kubeconfig "$kc" config view -o "jsonpath={.contexts[?(@.name==\"$CTX\")].context.user}")
	ns_ctx() { kubectl --kubeconfig "$kc" config set-context tkm-ns --cluster="$cluster" --user="$user" --namespace="$1" >/dev/null; }
	ns_ctx "$NS"
	k -n "$NS" create configmap tkm-ns-a --from-literal=a=1 >/dev/null 2>&1
	audit=${TK_SPOOL%/*}/audit.log
	: >"$audit"
	nsguard() {
		env TERM_PROGRAM=tern TERN_PANE=7 TKUBE_SPOOL="$TK_SPOOL" TERN_BIN="$fake" TK_REPO="$TK_REPO" \
			KUBECONFIG="$kc" TKUBE_GUARD_TIMEOUT=120 sh "$TK_REPO/shell/tern-kube-guard" kubectl "$@"
	}

	out=$(TK_GUARD_NAME=guard-ns-after TK_GUARD_DECISION=approve \
		TK_GUARD_EDIT_AFTER="kubectl --kubeconfig '$kc' config set-context tkm-ns --namespace=default >/dev/null" \
		nsguard --context tkm-ns delete configmap tkm-ns-a 2>&1)
	st=$?
	tk_log "kubens after approval: rc=$st $out"
	printf '    kubens after approval: guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	if [ $st = 1 ]; then tk_ok "guard refused (rc=1)"; else tk_fail "guard rc=$st, want 1"; fi
	case $out in
	*"now defaults to namespace 'default', but the approval previewed '$NS'"*) tk_ok "the guard names both namespaces" ;;
	*) tk_fail "no namespace refusal in the guard output" ;;
	esac
	case $out in *NotFound*) tk_fail "kubectl ran in another namespace" ;; *) tk_ok "kubectl never ran" ;; esac
	tk_check "tkm-ns-a survives in $NS" k -n "$NS" get configmap tkm-ns-a

	ns_ctx "$NS"
	out=$(TK_GUARD_NAME=guard-ns-before TK_GUARD_DECISION=approve \
		TK_GUARD_EDIT="kubectl --kubeconfig '$kc' config set-context tkm-ns --namespace=default >/dev/null" \
		nsguard --context tkm-ns delete configmap tkm-ns-a 2>&1)
	st=$?
	tk_log "kubens before approval: rc=$st $out"
	printf '    kubens before approval: guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	if [ $st = 1 ]; then tk_ok "nothing approved (rc=1)"; else tk_fail "guard rc=$st, want 1"; fi
	grep -q "now defaults to namespace default (previewed: $NS)" "$TK_REPO/.sandbox/mutate-it/guard-ns-before/evidence.log" &&
		tk_ok "the block refused at approval" || tk_fail "no block refusal recorded"
	tk_check "tkm-ns-a survives in $NS" k -n "$NS" get configmap tkm-ns-a

	ns_ctx "$NS"
	out=$(TK_GUARD_NAME=guard-ns-ok TK_GUARD_DECISION=approve nsguard --context tkm-ns delete configmap tkm-ns-a 2>&1)
	st=$?
	tk_log "namespace unchanged: rc=$st $out"
	printf '    namespace unchanged: guard rc=%s: %s\n' "$st" "$(printf '%s' "$out" | tr '\n' ' ')"
	if [ $st = 0 ]; then tk_ok "approved delete ran"; else tk_fail "guard rc=$st, want 0"; fi
	tk_check "tkm-ns-a deleted from $NS" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-ns-a"
	tk_log "audit: $(cat "$audit")"
	grep -q "\"decision\":\"executed\",\"mode\":\"guard\",\"op\":\"delete\",\"family\":\"delete\",\"context\":\"tkm-ns\",\"context_source\":\"flag\",\"namespace\":\"$NS\",.*\"exit_code\":0," "$audit" &&
		tk_ok "the outcome record names the executed namespace" || tk_fail "no executed record with namespace $NS"
	rm -f "$kc"
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
# The last driver pass prints only S_* assignments: the scenario sources them.
cp "$TK_W/driver.out" "$TK_W/preview.state"
[ -n "${TK_GUARD_EDIT:-}" ] && sh -c "$TK_GUARD_EDIT"
# TK_GUARD_COPY=1 presses y (copy the command) before deciding.
[ -n "${TK_GUARD_COPY:-}" ] && tk_key y y >>"$TK_REPO/.sandbox/mutate-it/guard.out"
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
cp "$TK_W/driver.out" "$TK_W/final.state"
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

# Track 1 guarded verbs ----------------------------------------------------------

fresh() { # MANIFEST...: recreate the objects of manifests/MANIFEST (foreground deletion drops old ReplicaSets too)
	for f in "$@"; do
		k delete -f "$M/$f" --ignore-not-found --cascade=foreground --wait=true >/dev/null 2>&1
		k apply -f "$M/$f" >/dev/null || tk_fail "cannot create $f"
	done
}

gone() { # MANIFEST...
	for f in "$@"; do
		k delete -f "$M/$f" --ignore-not-found --wait=false >/dev/null 2>&1
	done
}

live() { # RESOURCE JSONPATH
	k -n "$NS" get "$1" -o jsonpath="$2" 2>&1
}

expect_live() { # DESCRIPTION WANT RESOURCE JSONPATH
	got=$(live "$3" "$4")
	if [ "$got" = "$2" ]; then tk_ok "$1"; else tk_fail "$1: want '$2', got '$got'"; fi
}

rs_count() { # APP
	k -n "$NS" get rs -l "app=$1" -o name 2>/dev/null | wc -l | tr -d ' '
}

wait_until() { # SECONDS COMMAND...
	n=$1
	shift
	while ! "$@" >/dev/null 2>&1; do
		n=$((n - 1))
		[ "$n" -le 0 ] && return 1
		sleep 1
	done
}

rs_at_least() { # APP N
	[ "$(rs_count "$1")" -ge "$2" ]
}

revision_listed() { # DEPLOYMENT REVISION
	k -n "$NS" rollout history "deployment/$1" | grep -q "^$2 "
}

# tkm-undo with revision 1 = pause:3.9 and revision 2 = pause:3.10 (live).
undo_setup() {
	fresh rollout/tkm-undo.yaml
	wait_until 60 rs_at_least tkm-undo 1 &&
		k -n "$NS" set image deployment/tkm-undo main=registry.k8s.io/pause:3.10 >/dev/null &&
		wait_until 60 revision_listed tkm-undo 2 ||
		tk_fail "tkm-undo did not reach two revisions"
}

GUARD_FAKE=$TK_REPO/.sandbox/mutate-it/bin/tern

guard_scenario() { # NAME: evidence dir for a scenario that runs the real guard
	mkdir -p "$(dirname "$GUARD_FAKE")"
	guard_fake_tern "$GUARD_FAKE"
	: >"$TK_REPO/.sandbox/mutate-it/guard.out"
	printf '\n== %s\n' "$1"
	TK_W=$TK_REPO/.sandbox/mutate-it/$1
	rm -rf "$TK_W"
	mkdir -p "$TK_W"
	: >"$TK_W/evidence.log"
}

guard_kubectl() { # ARGS: `kubectl ARGS` through the real guard; the fake tern plays block $TK_GUARD_NAME
	env TERM_PROGRAM=tern TERN_PANE=7 TKUBE_SPOOL="$TK_SPOOL" TERN_BIN="$GUARD_FAKE" TK_REPO="$TK_REPO" \
		KUBECONFIG="$KC" TKUBE_GUARD_TIMEOUT=120 sh "$TK_REPO/shell/tern-kube-guard" kubectl "$@"
}

guard_log() { # WHAT STATUS OUTPUT
	tk_log "$1: rc=$2 $3"
	printf '    %s: guard rc=%s: %s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ')"
}

block_state() { # NAME preview|final: the S_* state the fake tern saved for block NAME
	f=$TK_REPO/.sandbox/mutate-it/$1/$2.state
	if [ -f "$f" ]; then
		# shellcheck disable=SC1090
		. "$f"
		tk_log "block $1 $2: phase=$S_phase tier=$S_tier token=$S_token steps=[$S_steps] reasons=[$S_reasons] errors=[$S_errors] confirm_error=[$S_confirm_error]"
	else
		tk_fail "block $1 never ran ($2.state missing)"
	fi
}

edit_editor() { # NAME SED_EXPR: prints the path of an editor script applying SED_EXPR (no ') in place
	ed=$TK_REPO/.sandbox/mutate-it/bin/editor-$1
	mkdir -p "$(dirname "$ed")"
	printf '#!/bin/sh\nsed '\''%s'\'' "$1" >"$1.tk" && cat "$1.tk" >"$1" && rm -f "$1.tk"\n' "$2" >"$ed"
	chmod +x "$ed"
	printf '%s' "$ed"
}

NODE=

uncordon_node() {
	[ -n "$NODE" ] && k uncordon "$NODE" >/dev/null 2>&1
	return 0
}

# Every node scenario leaves the kind node schedulable, even when interrupted.
node_begin() {
	NODE=$(k get nodes -o jsonpath='{.items[0].metadata.name}')
	trap uncordon_node EXIT
	trap 'uncordon_node; exit 130' INT TERM
}

node_link() { # op
	printf 'tern-kube://mutate?op=%s&kind=node&name=%s&context=%s&source=chosen' "$1" "$NODE" "$CTX"
}

expect_schedulable() { # DESCRIPTION
	expect_live "$1" "" "node/$NODE" '{.spec.unschedulable}'
}

scenario_label_one() {
	fresh meta/tkm-label.yaml
	tk_begin label-one "$(link label configmap tkm-label)"
	tk_expect phase input
	tk_effects_lacks run
	tk_type tier=gold
	tk_key enter
	tk_expect phase ready
	tk_expect tier simple
	tk_expect_has steps "targets=ok"
	tk_expect_has steps "after=ok"
	tk_expect segments "modify:ConfigMap/tkm-label"
	tk_expect_line + "tier: gold"
	expect_live "the preview labelled nothing" "" configmap/tkm-label '{.metadata.labels.tier}'
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_live "tier=gold after the label" gold configmap/tkm-label '{.metadata.labels.tier}'
	gone meta/tkm-label.yaml
}

# Links name one object; a selector arrives through the shell guard.
scenario_label_selector_typed() {
	fresh meta/tkm-sel.yaml
	guard_scenario label-selector-typed
	out=$(TK_GUARD_NAME=label-selector-typed-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" -n "$NS" label configmap -l tkm-sel=yes tier=gold 2>&1)
	st=$?
	guard_log "label -l" "$st" "$out"
	block_state label-selector-typed-block preview
	tk_expect phase ready
	tk_expect tier typed
	tk_expect token "label 2 resources"
	tk_expect_has reasons "typed:broad-selector"
	tk_expect_has segments "modify:ConfigMap/tkm-sel-1"
	tk_expect_has segments "modify:ConfigMap/tkm-sel-2"
	block_state label-selector-typed-block final
	tk_expect phase closed
	if [ "$st" = 0 ]; then tk_ok "guard executed after the typed approval"; else tk_fail "guard rc=$st"; fi
	expect_live "tkm-sel-1 labelled" gold configmap/tkm-sel-1 '{.metadata.labels.tier}'
	expect_live "tkm-sel-2 labelled" gold configmap/tkm-sel-2 '{.metadata.labels.tier}'
	gone meta/tkm-sel.yaml
}

scenario_label_conflict_fails() {
	fresh meta/tkm-label.yaml
	k -n "$NS" label configmap tkm-label tier=gold >/dev/null
	tk_begin label-conflict-fails "$(link label configmap tkm-label)"
	tk_type tier=silver
	tk_key enter
	tk_expect phase ready
	tk_expect tier blocked
	tk_expect_has steps "after=failed"
	tk_expect_has reasons "blocked:preview-failed"
	tk_expect_has view "already has a value"
	tk_key enter
	tk_effects_lacks run "'exec'"
	expect_live "tier still gold" gold configmap/tkm-label '{.metadata.labels.tier}'
	gone meta/tkm-label.yaml
}

scenario_annotate_overwrite() {
	fresh meta/tkm-annot.yaml
	tk_begin annotate-overwrite "$(link annotate configmap tkm-annot)"
	tk_expect phase input
	tk_type "tkm-note=new --overwrite"
	tk_key enter
	tk_expect phase ready
	tk_expect_has command "--overwrite"
	tk_expect_has reasons "simple:overwrites"
	tk_expect_line - "tkm-note: old"
	tk_expect_line + "tkm-note: new"
	expect_live "the preview kept the old value" old configmap/tkm-annot '{.metadata.annotations.tkm-note}'
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_live "tkm-note=new" new configmap/tkm-annot '{.metadata.annotations.tkm-note}'
	gone meta/tkm-annot.yaml
}

scenario_patch_merge() {
	fresh patch/tkm-patch.yaml
	tk_begin patch-merge "$(link patch deployment tkm-patch)"
	tk_expect phase input
	tk_keys backspace 40
	tk_type '--type=merge {"spec":{"replicas":2}}'
	tk_key enter
	tk_expect phase ready
	tk_expect_has command "--type=merge"
	tk_expect tier simple
	tk_expect_has steps "after=ok"
	tk_expect segments "modify:Deployment/tkm-patch"
	tk_expect_line - "replicas: 1"
	tk_expect_line + "replicas: 2"
	tk_expect_lacks diff_text "generation"
	expect_live "the preview kept 1 replica" 1 deployment/tkm-patch '{.spec.replicas}'
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_live "spec.replicas=2" 2 deployment/tkm-patch '{.spec.replicas}'
	gone patch/tkm-patch.yaml
}

# A freshly created cluster (CI) has no fixture world, so the suite installs
# the Widget CRD itself; applying an unchanged CRD is a no-op.
widget_crd() {
	k apply -f "$TK_REPO/tests/integration/manifests/crd/crd.yaml" >/dev/null &&
		k wait --for=condition=Established --timeout=60s crd/widgets.lens.example.com >/dev/null ||
		tk_fail "cannot install the Widget CRD"
}

scenario_patch_cr_merge() {
	widget_crd
	fresh patch/tkm-widget.yaml
	tk_begin patch-cr-merge "$(link patch widgets.lens.example.com tkm-widget)"
	tk_expect phase input
	tk_note "custom resources default to a JSON merge patch (prefilled)"
	tk_type '{"spec":{"size":3}}'
	tk_key enter
	tk_expect phase ready
	tk_expect_has command "--type=merge"
	tk_expect segments "modify:Widget/tkm-widget"
	tk_expect_line - "size: 1"
	tk_expect_line + "size: 3"
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_live "widget spec.size=3" 3 widgets.lens.example.com/tkm-widget '{.spec.size}'
	gone patch/tkm-widget.yaml
}

scenario_patch_json_typed() {
	fresh patch/tkm-patch-cm.yaml
	tk_begin patch-json-typed "$(link patch configmap tkm-patch-cm)"
	tk_keys backspace 40
	tk_type '--type=json [{"op":"replace","path":"/data/k","value":"v2"}]'
	tk_key enter
	tk_expect phase ready
	tk_expect tier typed
	tk_expect token tkm-patch-cm
	tk_expect_has reasons "typed:json-patch"
	tk_expect_line - "k: v1"
	tk_expect_line + "k: v2"
	tk_key enter
	tk_effects_lacks run "'exec'"
	tk_type tkm-
	tk_key enter
	tk_effects_lacks run "'exec'"
	expect_live "an inexact token patches nothing" v1 configmap/tkm-patch-cm '{.data.k}'
	tk_type patch-cm
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_live "data.k=v2" v2 configmap/tkm-patch-cm '{.data.k}'
	gone patch/tkm-patch-cm.yaml
}

scenario_patch_file_changed_refused() {
	fresh patch/tkm-patch-cm.yaml
	work=$TK_REPO/.sandbox/mutate-it/files
	mkdir -p "$work"
	printf '{"data":{"k":"v2"}}\n' >"$work/tkm-patch.json"
	printf '{"data":{"k":"v3"}}\n' >"$work/tkm-patch-v3.json"
	guard_scenario patch-file-changed-refused
	out=$(TK_GUARD_NAME=patch-file-changed-block TK_GUARD_DECISION=approve \
		TK_GUARD_EDIT="cp '$work/tkm-patch-v3.json' '$work/tkm-patch.json'" \
		guard_kubectl --context "$CTX" -n "$NS" patch configmap tkm-patch-cm --type=merge --patch-file "$work/tkm-patch.json" 2>&1)
	st=$?
	guard_log "patch --patch-file edited before approval" "$st" "$out"
	block_state patch-file-changed-block preview
	tk_expect_line + "k: v2"
	block_state patch-file-changed-block final
	# The request pins the file: the block tells the user to run it again.
	tk_expect_has errors "fingerprint mismatch"
	tk_expect_has errors "Run the command again"
	if [ "$st" != 0 ]; then tk_ok "guard refused (rc=$st)"; else tk_fail "the edited patch file was applied"; fi
	expect_live "data.k unchanged" v1 configmap/tkm-patch-cm '{.data.k}'
	gone patch/tkm-patch-cm.yaml
}

scenario_undo_previous() {
	undo_setup
	tk_begin undo-previous "$(link undo deployment tkm-undo)"
	tk_expect phase ready
	tk_expect tier typed
	tk_expect token tkm-undo
	tk_expect_has reasons "typed:undo"
	tk_expect_has steps "history=ok"
	tk_expect_has steps "dry-run=ok"
	tk_expect_has steps "revision:apps.v1.Deployment.$NS.tkm-undo=ok"
	tk_expect segments "modify:Deployment/tkm-undo"
	tk_expect_line - "image: registry.k8s.io/pause:3.10"
	tk_expect_line + "image: registry.k8s.io/pause:3.9"
	expect_live "the preview kept pause:3.10" registry.k8s.io/pause:3.10 deployment/tkm-undo '{.spec.template.spec.containers[0].image}'
	tk_type tkm-undo
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_live "rolled back to pause:3.9" registry.k8s.io/pause:3.9 deployment/tkm-undo '{.spec.template.spec.containers[0].image}'
	gone rollout/tkm-undo.yaml
}

# Links carry no revision; --to-revision arrives through the shell guard.
scenario_undo_to_revision() {
	undo_setup
	k -n "$NS" set image deployment/tkm-undo main=registry.k8s.io/pause:3.8 >/dev/null
	wait_until 60 revision_listed tkm-undo 3 || tk_fail "tkm-undo did not reach revision 3"
	guard_scenario undo-to-revision
	out=$(TK_GUARD_NAME=undo-to-revision-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" -n "$NS" rollout undo deployment/tkm-undo --to-revision=1 2>&1)
	st=$?
	guard_log "rollout undo --to-revision=1" "$st" "$out"
	block_state undo-to-revision-block preview
	tk_expect tier typed
	tk_expect token tkm-undo
	tk_expect_has steps "revision:apps.v1.Deployment.$NS.tkm-undo=ok"
	tk_expect_line - "image: registry.k8s.io/pause:3.8"
	tk_expect_line + "image: registry.k8s.io/pause:3.9"
	if [ "$st" = 0 ]; then tk_ok "guard executed after approval"; else tk_fail "guard rc=$st"; fi
	expect_live "revision 1's pause:3.9 (not the previous 3.10)" registry.k8s.io/pause:3.9 deployment/tkm-undo '{.spec.template.spec.containers[0].image}'
	gone rollout/tkm-undo.yaml
}

scenario_undo_single_revision_fails() {
	fresh rollout/tkm-single.yaml
	wait_until 60 rs_at_least tkm-single 1 || tk_fail "tkm-single has no ReplicaSet"
	tk_begin undo-single-revision-fails "$(link undo deployment tkm-single)"
	tk_expect phase ready
	tk_expect tier blocked
	tk_expect_has reasons "blocked:preview-failed"
	tk_expect_has view "no rollout history"
	tk_key enter
	tk_effects_lacks run "'exec'"
	expect_live "image unchanged" registry.k8s.io/pause:3.10 deployment/tkm-single '{.spec.template.spec.containers[0].image}'
	gone rollout/tkm-single.yaml
}

scenario_undo_verify_refuses() {
	undo_setup
	tk_begin undo-verify-refuses "$(link undo deployment tkm-undo)"
	tk_expect phase ready
	tk_note "someone rolls out between preview and confirm (revision 3)"
	k -n "$NS" set image deployment/tkm-undo main=registry.k8s.io/pause:3.9 >/dev/null
	wait_until 60 revision_listed tkm-undo 3 || tk_fail "tkm-undo did not reach revision 3"
	tk_type tkm-undo
	tk_key enter
	tk_expect phase ready
	tk_expect_has confirm_error "A rollout happened since the preview"
	tk_effects_lacks run "'exec'"
	expect_live "the new rollout's image stays" registry.k8s.io/pause:3.9 deployment/tkm-undo '{.spec.template.spec.containers[0].image}'
	gone rollout/tkm-undo.yaml
}

# (b) A selector is resolved again when kubectl runs: the block re-reads the
# set at confirm and refuses when it changed (an object added, or deleted and
# re-created under the same name), before anything is deleted.
selx_file() { # NAME: a manifest of a configmap the selection scenarios select
	f=$TK_REPO/.sandbox/mutate-it/files/$1.yaml
	mkdir -p "$(dirname "$f")"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    tkm-selx: "yes"\ndata:\n  k: v\n' \
		"$1" "$NS" >"$f"
	printf '%s' "$f"
}

selx_reset() { # NAME...: only these configmaps carry the label
	k -n "$NS" delete configmap -l tkm-selx=yes --ignore-not-found --wait=true >/dev/null 2>&1
	for n in "$@"; do
		k apply -f "$(selx_file "$n")" >/dev/null || tk_fail "cannot create $n"
	done
}

selx_count() {
	k -n "$NS" get configmap -l tkm-selx=yes -o name 2>/dev/null | wc -l | tr -d ' '
}

scenario_selection_unchanged() {
	selx_reset tkm-selx-a tkm-selx-b
	guard_scenario selection-unchanged
	out=$(TK_GUARD_NAME=selection-unchanged-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" -n "$NS" delete configmap -l tkm-selx=yes 2>&1)
	st=$?
	guard_log "delete -l (unchanged)" "$st" "$out"
	block_state selection-unchanged-block final
	tk_expect phase closed
	if [ "$st" = 0 ]; then tk_ok "deleted after the re-check"; else tk_fail "guard rc=$st"; fi
	if [ "$(selx_count)" = 0 ]; then tk_ok "both configmaps deleted"; else tk_fail "$(selx_count) left"; fi
	tk_check "the block re-read the selection" grep -q "jsonpath={range .items" "$TK_REPO/.sandbox/mutate-it/selection-unchanged-block/evidence.log"
}

scenario_selection_added() {
	selx_reset tkm-selx-a tkm-selx-b
	late=$(selx_file tkm-selx-c)
	guard_scenario selection-added
	out=$(TK_GUARD_NAME=selection-added-block TK_GUARD_DECISION=approve \
		TK_GUARD_EDIT="kubectl --context $CTX apply -f '$late' >/dev/null" \
		guard_kubectl --context "$CTX" -n "$NS" delete configmap -l tkm-selx=yes 2>&1)
	st=$?
	guard_log "delete -l (a match added before confirm)" "$st" "$out"
	block_state selection-added-block final
	tk_expect phase ready
	tk_expect_has confirm_error "The selection now matches 3 object(s) (previewed 2)"
	tk_expect_has confirm_error "+ConfigMap $NS/tkm-selx-c"
	if [ "$st" != 0 ]; then tk_ok "the guard ran nothing (rc=$st)"; else tk_fail "guard rc=0"; fi
	if [ "$(selx_count)" = 3 ]; then tk_ok "nothing deleted"; else tk_fail "$(selx_count) configmaps left, want 3"; fi
	selx_reset
}

scenario_selection_recreated() {
	selx_reset tkm-selx-a tkm-selx-b
	again=$(selx_file tkm-selx-b)
	before=$(live configmap/tkm-selx-b '{.metadata.uid}')
	guard_scenario selection-recreated
	out=$(TK_GUARD_NAME=selection-recreated-block TK_GUARD_DECISION=approve \
		TK_GUARD_EDIT="kubectl --context $CTX -n $NS delete configmap tkm-selx-b --wait=true >/dev/null && kubectl --context $CTX apply -f '$again' >/dev/null" \
		guard_kubectl --context "$CTX" -n "$NS" delete configmap -l tkm-selx=yes 2>&1)
	st=$?
	guard_log "delete -l (a match re-created before confirm)" "$st" "$out"
	block_state selection-recreated-block final
	tk_expect phase ready
	tk_expect_has confirm_error "ConfigMap $NS/tkm-selx-b re-created since the preview"
	after=$(live configmap/tkm-selx-b '{.metadata.uid}')
	if [ -n "$after" ] && [ "$after" != "$before" ]; then tk_ok "tkm-selx-b has a new uid"; else tk_fail "uid $before -> $after"; fi
	if [ "$st" != 0 ]; then tk_ok "the guard ran nothing (rc=$st)"; else tk_fail "guard rc=0"; fi
	if [ "$(selx_count)" = 2 ]; then tk_ok "nothing deleted"; else tk_fail "$(selx_count) configmaps left, want 2"; fi
	selx_reset
}

scenario_pause_resume() {
	fresh rollout/tkm-pause.yaml
	tk_begin pause "$(link pause deployment tkm-pause)"
	tk_expect phase ready
	tk_expect tier simple
	tk_expect segments "modify:Deployment/tkm-pause"
	tk_expect_line + "paused: true"
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_live "spec.paused=true" true deployment/tkm-pause '{.spec.paused}'
	tk_begin pause-again "$(link pause deployment tkm-pause)"
	tk_expect phase ready
	tk_expect_has reasons "simple:already-paused"
	tk_expect segments ""
	tk_expect unchanged "apps.v1.Deployment.$NS.tkm-pause"
	tk_key escape
	tk_expect phase closed
	tk_effects_lacks run "'exec'"
	tk_begin resume "$(link resume deployment tkm-pause)"
	tk_expect phase ready
	tk_expect_line - "paused: true"
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	case $(live deployment/tkm-pause '{.spec.paused}') in
	'' | false) tk_ok "resumed" ;;
	*) tk_fail "still paused" ;;
	esac
	gone rollout/tkm-pause.yaml
}

scenario_cordon_uncordon() {
	node_begin
	tk_begin cordon "$(node_link cordon)"
	tk_expect phase ready
	# kind has one node: cordoning it leaves nothing schedulable, so the
	# node name must be typed.
	tk_expect tier typed
	tk_expect token "$NODE"
	tk_expect_has reasons "typed:last-schedulable-node"
	tk_expect_has steps "targets=ok"
	tk_expect_has steps "dry-run=ok"
	tk_expect_has reasons "simple:control-plane"
	tk_expect segments "modify:Node/$NODE"
	tk_expect_line + "unschedulable: true"
	expect_schedulable "the preview left the node schedulable"
	tk_type "$NODE"
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_live "node cordoned" true "node/$NODE" '{.spec.unschedulable}'
	tk_begin cordon-again "$(node_link cordon)"
	tk_expect_has reasons "simple:already-cordoned"
	tk_key escape
	tk_begin uncordon "$(node_link uncordon)"
	tk_expect phase ready
	tk_expect_line - "unschedulable: true"
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_schedulable "node uncordoned by the block"
	uncordon_node
}

scenario_drain_preflight() {
	node_begin
	fresh nodes/tkm-drain-bare.yaml
	k -n "$NS" wait --for=condition=PodScheduled pod/tkm-drain-bare --timeout=60s >/dev/null || tk_fail "tkm-drain-bare not scheduled"
	tk_begin drain-timeout "$(node_link drain)"
	tk_expect phase input
	tk_note "the prefilled --timeout=4m is not below the 120s execute timeout"
	tk_key enter
	case "$S_errors $S_confirm_error $S_view" in
	*"below mutations.execute_timeout_ms"*) tk_ok "native drain timeout refused before preview" ;;
	*) tk_fail "no execute-timeout refusal: errors=[$S_errors] confirm_error=[$S_confirm_error]" ;;
	esac
	tk_check "no drain step ran (only context resolution)" sh -c "! grep -q ' drain ' '$TK_W/effects.log'"
	tk_begin drain-preflight "$(node_link drain)"
	tk_keys backspace 60
	tk_type "--timeout=20s --pod-selector=app=tkm-drain-pre"
	tk_key enter
	tk_expect phase ready
	tk_expect tier blocked
	tk_expect_has reasons "blocked:preview-failed"
	tk_note "kubectl stops at the first failing filter per pod: local storage before no controller"
	tk_expect_has view "kubectl would cordon the node, then stop: pods with local storage (1 pod) (use --delete-emptydir-data)"
	tk_key enter
	tk_effects_lacks run "'exec'"
	tk_begin drain-preflight-forced "$(node_link drain)"
	tk_keys backspace 60
	tk_type "--delete-emptydir-data --force --timeout=20s --pod-selector=app=tkm-drain-pre"
	tk_key enter
	tk_expect phase ready
	tk_expect tier typed
	tk_expect token "$NODE"
	tk_expect_has reasons "typed:drain"
	tk_expect_has reasons "typed:force-unmanaged"
	tk_expect_has reasons "typed:emptydir-loss"
	tk_expect_has reasons "typed:control-plane"
	tk_key escape
	tk_expect phase closed
	tk_effects_lacks run "'exec'"
	expect_schedulable "previews never cordon"
	tk_check "tkm-drain-bare still exists" k -n "$NS" get pod tkm-drain-bare
	gone nodes/tkm-drain-bare.yaml
	uncordon_node
}

scenario_drain_pdb_blocked() {
	node_begin
	fresh nodes/tkm-drain.yaml nodes/tkm-drain-pdb.yaml
	k -n "$NS" rollout status deployment/tkm-drain --timeout=120s >/dev/null || tk_fail "tkm-drain not ready"
	pod=$(k -n "$NS" get pods -l app=tkm-drain -o jsonpath='{.items[*].metadata.name}')
	tk_begin drain-pdb-blocked "$(node_link drain)"
	tk_keys backspace 60
	tk_type "--ignore-daemonsets --timeout=10s --pod-selector=app=tkm-drain"
	tk_key enter
	tk_expect phase ready
	tk_expect tier typed
	tk_expect token "$NODE"
	tk_expect_has reasons "typed:pdb-blocked"
	tk_expect_has steps "evict="
	expect_schedulable "the preview left the node schedulable"
	tk_type "$NODE"
	tk_key enter
	tk_expect phase done
	if [ -n "$S_exec_status" ] && [ "$S_exec_status" != 0 ]; then tk_ok "drain gave up at its timeout (exit $S_exec_status)"; else tk_fail "drain exit '$S_exec_status', want non-zero"; fi
	expect_live "the PDB kept $pod" "$pod" "pod/$pod" '{.metadata.name}'
	expect_live "$pod is not terminating" "" "pod/$pod" '{.metadata.deletionTimestamp}'
	tk_begin drain-pdb-uncordon "$(node_link uncordon)"
	tk_expect phase ready
	tk_key enter
	tk_expect phase done
	expect_schedulable "node schedulable again"
	gone nodes/tkm-drain-pdb.yaml nodes/tkm-drain.yaml
	uncordon_node
}

scenario_drain_ok() {
	node_begin
	gone nodes/tkm-drain-pdb.yaml
	# drain-pdb-blocked deletes tkm-drain without waiting: a terminating pod of
	# it would be listed below but never previewed (drain skips it).
	k -n "$NS" wait --for=delete pod -l app=tkm-drain --timeout=60s >/dev/null 2>&1
	fresh nodes/tkm-drain.yaml
	k -n "$NS" rollout status deployment/tkm-drain --timeout=120s >/dev/null || tk_fail "tkm-drain not ready"
	pod=$(k -n "$NS" get pods -l app=tkm-drain -o jsonpath='{.items[*].metadata.name}')
	tk_begin drain-ok "$(node_link drain)"
	tk_keys backspace 60
	tk_type "--ignore-daemonsets --timeout=60s --pod-selector=app=tkm-drain"
	tk_key enter
	tk_expect phase ready
	tk_expect tier typed
	tk_expect token "$NODE"
	tk_expect_has reasons "typed:drain"
	tk_expect_lacks reasons "pdb-blocked"
	tk_expect_has steps "evict=ok"
	tk_expect_has view "$pod"
	tk_type "$NODE"
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	tk_check "$pod was evicted" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get pod '$pod'"
	expect_live "drain leaves the node cordoned" true "node/$NODE" '{.spec.unschedulable}'
	tk_begin drain-ok-uncordon "$(node_link uncordon)"
	tk_key enter
	tk_expect phase done
	expect_schedulable "node schedulable again"
	gone nodes/tkm-drain.yaml
	uncordon_node
}

edit_scenario() { # NAME SED_EXPR DECISION: guarded `kubectl edit configmap/tkm-edit` with a scripted editor
	fresh meta/tkm-edit.yaml
	guard_scenario "$1"
	ed=$(edit_editor "$1" "$2")
	out=$(TK_GUARD_NAME=$1-block TK_GUARD_DECISION=$3 KUBE_EDITOR=$ed \
		guard_kubectl --context "$CTX" -n "$NS" edit configmap/tkm-edit 2>&1)
	st=$?
	guard_log "edit" "$st" "$out"
}

scenario_edit_request() {
	edit_scenario edit-request 's/LEVEL: info/LEVEL: debug/' approve
	block_state edit-request-block preview
	tk_expect phase ready
	tk_expect tier simple
	tk_expect_has steps "convert-original=ok"
	tk_expect_has steps "convert-edited=ok"
	tk_expect_has steps "targets=ok"
	tk_expect_has steps "after:v1.ConfigMap.$NS.tkm-edit=ok"
	tk_expect segments "modify:ConfigMap/tkm-edit"
	tk_expect_line - "LEVEL: info"
	tk_expect_line + "LEVEL: debug"
	block_state edit-request-block final
	tk_expect phase closed
	tk_check "the block wrote an approve response" grep -q "^write .*resp-" "$TK_REPO/.sandbox/mutate-it/edit-request-block/effects.log"
	if [ "$st" = 0 ]; then tk_ok "kubectl edit applied after approval"; else tk_fail "kubectl edit rc=$st"; fi
	expect_live "LEVEL=debug" debug configmap/tkm-edit '{.data.LEVEL}'
	gone meta/tkm-edit.yaml
}

scenario_edit_renamed_blocked() {
	edit_scenario edit-renamed-blocked 's/^  name: tkm-edit$/  name: tkm-edit-renamed/' approve
	block_state edit-renamed-blocked-block preview
	tk_expect tier blocked
	tk_expect_has reasons "blocked:edit-renamed"
	block_state edit-renamed-blocked-block final
	tk_expect phase ready
	tk_check "the block wrote no response" sh -c "! grep -q '^write ' '$TK_REPO/.sandbox/mutate-it/edit-renamed-blocked-block/effects.log'"
	if [ "$st" != 0 ]; then tk_ok "kubectl edit failed (rc=$st)"; else tk_fail "kubectl edit succeeded"; fi
	case $out in
	*"your edit is saved"*) tk_ok "the refused edit was saved" ;;
	*) tk_fail "no saved-edit notice" ;;
	esac
	tk_check "no renamed object" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-edit-renamed"
	expect_live "tkm-edit unchanged" info configmap/tkm-edit '{.data.LEVEL}'
	gone meta/tkm-edit.yaml
}

# The server rejects the edit; approving is harmless: kubectl reopens the
# editor with the error, the unchanged second round cancels.
scenario_edit_invalid_approvable() {
	edit_scenario edit-invalid-approvable 's/tier: one/tier: "bad value!"/' approve
	block_state edit-invalid-approvable-block preview
	tk_expect phase ready
	tk_expect tier simple
	tk_expect_has reasons "simple:edit-rejected"
	tk_expect_has steps "after:v1.ConfigMap.$NS.tkm-edit=failed"
	block_state edit-invalid-approvable-block final
	tk_expect phase closed
	case $out in
	*"no valid changes were saved"*) tk_ok "kubectl reported the rejected edit" ;;
	*) tk_fail "kubectl did not report the rejection" ;;
	esac
	expect_live "label tier unchanged" one configmap/tkm-edit '{.metadata.labels.tier}'
	gone meta/tkm-edit.yaml
}

# Guard 1.2 verbs: set, replace (--force), taint, create, run, expose -------------

G12=guard12

g12_reset() { # removes what the guard12 scenarios create besides their manifests
	k -n "$NS" delete secret/tkm-g12-sec configmap/tkm-g12-dir job/tkm-g12-job cronjob/tkm-g12-cron \
		pod/tkm-g12-run pod/tkm-g12-att service/tkm-g12-svc --ignore-not-found --wait=true >/dev/null 2>&1
}

g12_work() { # a fresh scratch dir for a scenario's files
	d=$TK_REPO/.sandbox/mutate-it/files/$1
	rm -rf "$d"
	mkdir -p "$d"
	printf '%s' "$d"
}

block_dir() { # BLOCK
	printf '%s' "$TK_REPO/.sandbox/mutate-it/$1"
}

scenario_guard_set_image() {
	fresh "$G12/tkm-g12.yaml"
	guard_scenario guard-set-image
	out=$(TK_GUARD_NAME=guard-set-image-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" -n "$NS" set image deployment/tkm-g12 main=registry.k8s.io/pause:3.9 2>&1)
	st=$?
	guard_log "set image" "$st" "$out"
	block_state guard-set-image-block preview
	tk_expect phase ready
	tk_expect tier simple
	tk_expect_has reasons "simple:set-image"
	tk_expect_has steps "targets=ok"
	tk_expect_has steps "after=ok"
	tk_expect segments "modify:Deployment/tkm-g12"
	tk_expect_line - "image: registry.k8s.io/pause:3.10"
	tk_expect_line + "image: registry.k8s.io/pause:3.9"
	block_state guard-set-image-block final
	tk_expect phase closed
	if [ "$st" = 0 ]; then tk_ok "guard executed after approval"; else tk_fail "guard rc=$st"; fi
	expect_live "image is pause:3.9" registry.k8s.io/pause:3.9 deployment/tkm-g12 '{.spec.template.spec.containers[0].image}'
}

# kubectl prints nothing for an unchanged object: no change, never a deletion.
scenario_guard_set_noop() {
	fresh "$G12/tkm-g12.yaml"
	guard_scenario guard-set-noop
	out=$(TK_GUARD_NAME=guard-set-noop-block TK_GUARD_DECISION=deny \
		guard_kubectl --context "$CTX" -n "$NS" set image deployment/tkm-g12 main=registry.k8s.io/pause:3.10 2>&1)
	st=$?
	guard_log "set image (same image)" "$st" "$out"
	block_state guard-set-noop-block preview
	tk_expect phase ready
	tk_expect_has steps "after=ok"
	tk_expect_has reasons "no-change"
	tk_expect_lacks segments "delete:"
	tk_expect_lacks segments "modify:"
	if [ "$st" != 0 ]; then tk_ok "denied (rc=$st)"; else tk_fail "guard rc=0 after a denial"; fi
}

# tkm-g12 runs pause:3.10, tkm-g12b pause:3.9: only tkm-g12b changes.
scenario_guard_set_all_mixed() {
	fresh "$G12/tkm-g12.yaml"
	guard_scenario guard-set-all-mixed
	out=$(TK_GUARD_NAME=guard-set-all-mixed-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" -n "$NS" set image deployment -l tkm-g12=yes main=registry.k8s.io/pause:3.10 2>&1)
	st=$?
	guard_log "set image -l" "$st" "$out"
	block_state guard-set-all-mixed-block preview
	tk_expect phase ready
	tk_expect tier typed
	tk_expect_has reasons "typed:broad-selector"
	tk_expect segments "modify:Deployment/tkm-g12b"
	tk_expect_lacks segments "delete:"
	tk_expect_has unchanged "tkm-g12"
	block_state guard-set-all-mixed-block final
	tk_expect phase closed
	if [ "$st" = 0 ]; then tk_ok "guard executed after the typed approval"; else tk_fail "guard rc=$st"; fi
	expect_live "tkm-g12b now pause:3.10" registry.k8s.io/pause:3.10 deployment/tkm-g12b '{.spec.template.spec.containers[0].image}'
	expect_live "tkm-g12 kept pause:3.10" registry.k8s.io/pause:3.10 deployment/tkm-g12 '{.spec.template.spec.containers[0].image}'
	gone "$G12/tkm-g12.yaml"
}

scenario_guard_set_env_stdin_refused() {
	fresh "$G12/tkm-g12.yaml"
	guard_scenario guard-set-env-stdin
	rm -rf "$(block_dir guard-set-env-stdin-block)"
	out=$(echo 'X=1' | TK_GUARD_NAME=guard-set-env-stdin-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" -n "$NS" set env deployment/tkm-g12 -e - 2>&1)
	st=$?
	guard_log "set env -e -" "$st" "$out"
	if [ "$st" != 0 ]; then tk_ok "refused (rc=$st)"; else tk_fail "guard rc=0"; fi
	case $out in *stdin*) tk_ok "the refusal names stdin" ;; *) tk_fail "no stdin refusal" ;; esac
	tk_check "no approve block opened" sh -c "[ ! -f '$(block_dir guard-set-env-stdin-block)/preview.state' ]"
	expect_live "no env added" "" deployment/tkm-g12 '{.spec.template.spec.containers[0].env}'
	gone "$G12/tkm-g12.yaml"
}

scenario_guard_replace() {
	fresh "$G12/tkm-g12-cfg.yaml"
	work=$(g12_work replace)
	sed 's/LOG_LEVEL: info/LOG_LEVEL: debug/' "$M/$G12/tkm-g12-cfg.yaml" >"$work/cfg.yaml"
	guard_scenario guard-replace
	out=$(TK_GUARD_NAME=guard-replace-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" replace -f "$work/cfg.yaml" 2>&1)
	st=$?
	guard_log "replace -f" "$st" "$out"
	block_state guard-replace-block preview
	tk_expect phase ready
	tk_expect tier simple
	tk_expect_has reasons "simple:replace"
	tk_expect_has reasons "replace-no-rv"
	tk_expect segments "modify:ConfigMap/tkm-g12-cfg"
	tk_expect_line - "LOG_LEVEL: info"
	tk_expect_line + "LOG_LEVEL: debug"
	block_state guard-replace-block final
	tk_expect phase closed
	if [ "$st" = 0 ]; then tk_ok "replaced after approval"; else tk_fail "guard rc=$st"; fi
	expect_live "LOG_LEVEL=debug" debug configmap/tkm-g12-cfg '{.data.LOG_LEVEL}'
}

# A file with a stale resourceVersion: the dry run conflicts, nothing changes.
scenario_guard_replace_conflict() {
	fresh "$G12/tkm-g12-cfg.yaml"
	work=$(g12_work replace-conflict)
	k -n "$NS" get configmap tkm-g12-cfg -o yaml | sed 's/LOG_LEVEL: info/LOG_LEVEL: debug/' >"$work/cfg.yaml"
	k -n "$NS" label configmap tkm-g12-cfg tkm-bump=1 >/dev/null || tk_fail "cannot bump the resourceVersion"
	guard_scenario guard-replace-conflict
	out=$(TK_GUARD_NAME=guard-replace-conflict-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" replace -f "$work/cfg.yaml" 2>&1)
	st=$?
	guard_log "replace -f (stale resourceVersion)" "$st" "$out"
	block_state guard-replace-conflict-block preview
	tk_expect tier blocked
	tk_expect_has reasons "blocked:preview-failed"
	tk_expect_has view "the object has been modified"
	if [ "$st" != 0 ]; then tk_ok "nothing ran (rc=$st)"; else tk_fail "guard rc=0"; fi
	expect_live "LOG_LEVEL unchanged" info configmap/tkm-g12-cfg '{.data.LOG_LEVEL}'
	gone "$G12/tkm-g12-cfg.yaml"
}

# A selector change is immutable: only --force (delete + create) applies it.
scenario_guard_replace_force() {
	fresh "$G12/tkm-g12-imm.yaml"
	work=$(g12_work replace-force)
	sed 's/app: tkm-g12-imm$/app: tkm-g12-imm2/' "$M/$G12/tkm-g12-imm.yaml" >"$work/imm.yaml"
	before=$(live deployment/tkm-g12-imm '{.metadata.uid}')
	guard_scenario guard-replace-force
	out=$(TK_GUARD_NAME=guard-replace-force-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" replace --force -f "$work/imm.yaml" 2>&1)
	st=$?
	guard_log "replace --force -f" "$st" "$out"
	block_state guard-replace-force-block preview
	tk_expect phase ready
	tk_expect tier typed
	tk_expect_has reasons "typed:replace-force"
	tk_expect_has reasons "force-needed"
	tk_expect_has steps "dry-run=ok"
	tk_expect_has view "field is immutable"
	tk_check "no dry run carries --force" sh -c "! grep -e '--dry-run=server' '$(block_dir guard-replace-force-block)/effects.log' | grep -q -e '--force'"
	block_state guard-replace-force-block final
	tk_expect phase closed
	if [ "$st" = 0 ]; then tk_ok "replaced after the typed approval"; else tk_fail "guard rc=$st"; fi
	after=$(live deployment/tkm-g12-imm '{.metadata.uid}')
	if [ -n "$after" ] && [ "$after" != "$before" ]; then tk_ok "new uid ($before -> $after)"; else tk_fail "uid $before -> $after"; fi
	expect_live "the new selector" tkm-g12-imm2 deployment/tkm-g12-imm '{.spec.selector.matchLabels.app}'
	k -n "$NS" delete deployment tkm-g12-imm --ignore-not-found --wait=false >/dev/null 2>&1
}

# Taints: a key per run; every exit removes it (and uncordons) like uncordon_node.
TAINT_KEY=

untaint_node() {
	uncordon_node
	[ -n "$NODE" ] && [ -n "$TAINT_KEY" ] && k taint node "$NODE" "$TAINT_KEY-" >/dev/null 2>&1
	return 0
}

taint_begin() {
	NODE=$(k get nodes -o jsonpath='{.items[0].metadata.name}')
	TAINT_KEY=tkm-taint-$$
	trap untaint_node EXIT
	trap 'untaint_node; exit 130' INT TERM
}

node_taints() {
	k get node "$NODE" -o jsonpath='{.spec.taints}' 2>&1
}

# NoExecute would evict coredns and the fixtures: only ever denied here.
scenario_taint_noexecute_deny() {
	taint_begin
	guard_scenario taint-noexecute-deny
	out=$(TK_GUARD_NAME=taint-noexecute-block TK_GUARD_DECISION=deny \
		guard_kubectl --context "$CTX" taint node "$NODE" "$TAINT_KEY=x:NoExecute" 2>&1)
	st=$?
	guard_log "taint NoExecute (deny)" "$st" "$out"
	block_state taint-noexecute-block preview
	tk_expect phase ready
	tk_expect tier typed
	tk_expect_has reasons "typed:taint-noexecute"
	tk_expect_has steps "after=ok"
	tk_expect_has steps "pods:$NODE=ok"
	tk_expect_has view "coredns"
	tk_expect_lacks reasons "taint-evictions-unknown"
	tk_expect_line + "$TAINT_KEY"
	if [ "$st" != 0 ]; then tk_ok "denied (rc=$st)"; else tk_fail "guard rc=0 after a denial"; fi
	case $(node_taints) in
	*"$TAINT_KEY"*) tk_fail "the node carries $TAINT_KEY" ;;
	*) tk_ok "node taints unchanged" ;;
	esac
	untaint_node
}

scenario_taint_prefer_roundtrip() {
	taint_begin
	guard_scenario taint-prefer-roundtrip
	out=$(TK_GUARD_NAME=taint-prefer-add-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" taint node "$NODE" "$TAINT_KEY=1:PreferNoSchedule" 2>&1)
	st=$?
	guard_log "taint PreferNoSchedule" "$st" "$out"
	block_state taint-prefer-add-block preview
	tk_expect phase ready
	tk_expect_has reasons "taint-prefer"
	tk_expect_lacks reasons "taint-noexecute"
	tk_expect_line + "$TAINT_KEY"
	if [ "$st" = 0 ]; then tk_ok "tainted after approval"; else tk_fail "guard rc=$st"; fi
	case $(node_taints) in
	*"$TAINT_KEY"*PreferNoSchedule* | *PreferNoSchedule*"$TAINT_KEY"*) tk_ok "node has $TAINT_KEY:PreferNoSchedule" ;;
	*) tk_fail "no $TAINT_KEY taint: $(node_taints)" ;;
	esac
	out=$(TK_GUARD_NAME=taint-prefer-remove-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" taint node "$NODE" "$TAINT_KEY:PreferNoSchedule-" 2>&1)
	st=$?
	guard_log "taint remove" "$st" "$out"
	block_state taint-prefer-remove-block preview
	tk_expect_has reasons "simple:taint-remove"
	tk_expect_line - "$TAINT_KEY"
	if [ "$st" = 0 ]; then tk_ok "untainted after approval"; else tk_fail "guard rc=$st"; fi
	case $(node_taints) in
	*"$TAINT_KEY"*) tk_fail "$TAINT_KEY still on the node" ;;
	*) tk_ok "$TAINT_KEY removed" ;;
	esac
	untaint_node
	expect_schedulable "the node stays schedulable"
}

# The literal never reaches the view, the copy, the audit logs or the response.
scenario_guard_create_secret_masked() {
	g12_reset
	lit=tkm-S3cr3t-g12
	guard_scenario guard-create-secret-masked
	b=$(block_dir guard-create-secret-block)
	out=$(TK_GUARD_NAME=guard-create-secret-block TK_GUARD_DECISION=approve TK_GUARD_COPY=1 \
		guard_kubectl --context "$CTX" -n "$NS" create secret generic tkm-g12-sec "--from-literal=password=$lit" 2>&1)
	st=$?
	guard_log "create secret generic" "$st" "$out"
	block_state guard-create-secret-block preview
	tk_expect phase ready
	tk_expect_has reasons "secret-masked"
	tk_expect_has command "--from-literal=password=<redacted>"
	tk_expect_lacks command "$lit"
	tk_expect segments "create:Secret/tkm-g12-sec"
	if [ "$st" = 0 ]; then tk_ok "created after approval"; else tk_fail "guard rc=$st"; fi
	tk_check "the secret holds the literal" sh -c \
		"[ \"\$(kubectl --kubeconfig '$KC' --context $CTX -n $NS get secret tkm-g12-sec -o jsonpath='{.data.password}' | base64 -d)\" = '$lit' ]"
	tk_check "copied the masked command" grep -q "^copy .*password=<redacted>" "$b/effects.log"
	tk_check "the copy lacks the literal" sh -c "! grep '^copy ' '$b/effects.log' | grep -q '$lit'"
	tk_check "view.txt lacks the literal" sh -c "! grep -q '$lit' '$b/view.txt'"
	tk_check "the block's audit.log lacks the literal" sh -c "[ -s '$b/audit.log' ] && ! grep -q '$lit' '$b/audit.log'"
	tk_check "the guard's audit.log lacks the literal" sh -c "! grep -q '$lit' '$TK_REPO/.sandbox/mutate-it/audit.log'"
	tk_check "the response was written" grep -q "^wrote .*resp-.*audit=" "$b/evidence.log"
	tk_check "the response template lacks the literal" sh -c "! grep '^wrote .*resp-' '$b/evidence.log' | grep -q '$lit'"
	g12_reset
}

# Files inside a --from-file directory are fingerprinted like -f files.
scenario_guard_create_fromdir_fingerprint() {
	g12_reset
	work=$(g12_work fromdir)
	mkdir -p "$work/cfg/sub"
	printf 'one\n' >"$work/cfg/a.txt"
	printf 'two\n' >"$work/cfg/b.txt"
	printf 'skipped\n' >"$work/cfg/sub/c.txt"
	guard_scenario guard-create-fromdir
	out=$(TK_GUARD_NAME=guard-create-fromdir-block TK_GUARD_DECISION=approve \
		TK_GUARD_EDIT_AFTER="printf 'changed\n' >'$work/cfg/b.txt'" \
		guard_kubectl --context "$CTX" -n "$NS" create configmap tkm-g12-dir "--from-file=$work/cfg" 2>&1)
	st=$?
	guard_log "create configmap --from-file=DIR (edited after approval)" "$st" "$out"
	block_state guard-create-fromdir-block preview
	tk_expect phase ready
	tk_expect segments "create:ConfigMap/tkm-g12-dir"
	tk_expect_has diff_text "a.txt"
	tk_expect_lacks diff_text "c.txt"
	case $out in
	*"fingerprint mismatch"*) tk_ok "the guard refused the edited directory" ;;
	*) tk_fail "no fingerprint mismatch" ;;
	esac
	if [ "$st" != 0 ]; then tk_ok "nothing ran (rc=$st)"; else tk_fail "guard rc=0"; fi
	tk_check "no configmap created" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get configmap tkm-g12-dir"
}

scenario_guard_create_job_from_cronjob() {
	g12_reset
	cronjob_manifest tkm-g12-cron | k apply -f - >/dev/null || tk_fail "cannot create tkm-g12-cron"
	guard_scenario guard-create-job
	out=$(TK_GUARD_NAME=guard-create-job-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" -n "$NS" create job tkm-g12-job --from=cronjob/tkm-g12-cron 2>&1)
	st=$?
	guard_log "create job --from=cronjob" "$st" "$out"
	block_state guard-create-job-block preview
	tk_expect phase ready
	tk_expect_has steps "dry-run=ok"
	block_state guard-create-job-block final
	tk_expect phase closed
	if [ "$st" = 0 ]; then tk_ok "created after approval"; else tk_fail "guard rc=$st"; fi
	expect_live "the job comes from the cronjob" manual job/tkm-g12-job '{.metadata.annotations.cronjob\.kubernetes\.io/instantiate}'
	g12_reset
}

scenario_guard_create_exists_blocked() {
	fresh "$G12/tkm-g12-cfg.yaml"
	guard_scenario guard-create-exists
	out=$(TK_GUARD_NAME=guard-create-exists-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" -n "$NS" create configmap tkm-g12-cfg --from-literal=LOG_LEVEL=trace 2>&1)
	st=$?
	guard_log "create configmap (exists)" "$st" "$out"
	block_state guard-create-exists-block preview
	tk_expect tier blocked
	tk_expect_has reasons "blocked:preview-failed"
	tk_expect_has view "already exists"
	if [ "$st" != 0 ]; then tk_ok "nothing ran (rc=$st)"; else tk_fail "guard rc=0"; fi
	expect_live "LOG_LEVEL unchanged" info configmap/tkm-g12-cfg '{.data.LOG_LEVEL}'
	gone "$G12/tkm-g12-cfg.yaml"
}

scenario_guard_run() {
	g12_reset
	guard_scenario guard-run
	out=$(TK_GUARD_NAME=guard-run-block TK_GUARD_DECISION=approve \
		guard_kubectl --context "$CTX" -n "$NS" run tkm-g12-run --image=registry.k8s.io/pause:3.10 --restart=Never 2>&1)
	st=$?
	guard_log "run" "$st" "$out"
	block_state guard-run-block preview
	tk_expect phase ready
	tk_expect_has steps "after=ok"
	tk_expect segments "create:Pod/tkm-g12-run"
	if [ "$st" = 0 ]; then tk_ok "pod created after approval"; else tk_fail "guard rc=$st"; fi
	expect_live "pod image" registry.k8s.io/pause:3.10 pod/tkm-g12-run '{.spec.containers[0].image}'
	g12_reset
}

# kubectl refuses --dry-run with attach flags: the preview drops them.
scenario_guard_run_attach_preview() {
	g12_reset
	guard_scenario guard-run-attach
	out=$(TK_GUARD_NAME=guard-run-attach-block TK_GUARD_DECISION=deny \
		guard_kubectl --context "$CTX" -n "$NS" run tkm-g12-att -it --rm --restart=Never --image=registry.k8s.io/pause:3.10 2>&1)
	st=$?
	guard_log "run -it --rm (deny)" "$st" "$out"
	block_state guard-run-attach-block preview
	tk_expect phase ready
	tk_expect_has steps "after=ok"
	tk_expect_has reasons "run-attach"
	tk_expect_has reasons "run-rm"
	tk_expect_has command "--rm"
	tk_check "a dry run ran" sh -c "grep -q -e '--dry-run=server' '$(block_dir guard-run-attach-block)/effects.log'"
	if grep -e '--dry-run=server' "$(block_dir guard-run-attach-block)/effects.log" |
		grep -Eq -e "(^| |')(-it|-i|-t|--rm|--tty|--stdin|--attach)('| |=|\$)"; then
		tk_fail "the dry run carries an attach flag"
	else
		tk_ok "the dry run has no -it/--rm/--tty/--stdin"
	fi
	if [ "$st" != 0 ]; then tk_ok "denied (rc=$st)"; else tk_fail "guard rc=0 after a denial"; fi
	tk_check "no pod" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get pod tkm-g12-att"
}

scenario_guard_expose_nodeport() {
	fresh "$G12/tkm-g12.yaml"
	g12_reset
	guard_scenario guard-expose-nodeport
	out=$(TK_GUARD_NAME=guard-expose-block TK_GUARD_DECISION=deny \
		guard_kubectl --context "$CTX" -n "$NS" expose deployment/tkm-g12 --name=tkm-g12-svc --type=NodePort --port=80 2>&1)
	st=$?
	guard_log "expose --type=NodePort (deny)" "$st" "$out"
	block_state guard-expose-block preview
	tk_expect phase ready
	tk_expect_has steps "targets=ok"
	tk_expect_has steps "after=ok"
	tk_expect_has reasons "public-service"
	tk_expect segments "create:Service/tkm-g12-svc"
	if [ "$st" != 0 ]; then tk_ok "denied (rc=$st)"; else tk_fail "guard rc=0 after a denial"; fi
	tk_check "no service" sh -c "! kubectl --kubeconfig '$KC' --context $CTX -n $NS get service tkm-g12-svc"
	gone "$G12/tkm-g12.yaml"
}

# helm rollback scenarios: releases of the fixture charts in their own
# namespace, helm pinned to .tools/bin/helm with throwaway HELM_*_HOME dirs
# (never the user's repositories or registry logins). They build on each
# other in this order; helm_cleanup removes the namespace.
HNS=${TK_IT_HELM_NS:-tern-test-helm-it}
HELM=${TK_IT_HELM:-$TK_REPO/.tools/bin/helm}
TK_HELM=${TK_HELM:-$HELM}
export TK_HELM
SHOP=$TK_REPO/tests/fixtures/gitops/helm/chart
STAGING=$TK_REPO/tests/fixtures/gitops/helm/values-staging.yaml
WEB=$TK_REPO/tests/fixtures/helm/web
TK_HELM_HOME=${TK_HELM_HOME:-${TMPDIR:-/tmp}/tk-mutate-it-helm}
HELM_CONFIG_HOME=$TK_HELM_HOME/config
HELM_CACHE_HOME=$TK_HELM_HOME/cache
HELM_DATA_HOME=$TK_HELM_HOME/data
export HELM_CONFIG_HOME HELM_CACHE_HOME HELM_DATA_HOME

h() {
	"$HELM" --kube-context "$CTX" --kubeconfig "$KC" -n "$HNS" "$@"
}

hlink() { # RELEASE REVISION [extra]
	printf 'tern-kube://mutate?op=rollback&release=%s&revision=%s&namespace=%s&context=%s&source=chosen%s' \
		"$1" "$2" "$HNS" "$CTX" "${3:-}"
}

expect_release() { # RELEASE REVISION STATUS DESCRIPTION: the newest revision
	row=$(h history "$1" --max 1 -o json 2>&1)
	case $row in
	*"\"revision\":$2,"*"\"status\":\"$3\""*"\"description\":\"$4\""*) tk_ok "$1 is at revision $2 ($3): $4" ;;
	*) tk_fail "$1: expected revision $2 ($3): $4, got $row" ;;
	esac
}

helm_up() { # helm args...: install/upgrade and wait, or fail the scenario
	h "$@" --wait --timeout 120s >/dev/null 2>"$TK_REPO/.sandbox/mutate-it/helm.err" ||
		tk_fail "helm $*: $(cat "$TK_REPO/.sandbox/mutate-it/helm.err")"
}

helm_sa_kubeconfig() { # SA: a kubeconfig for a ServiceAccount of $HNS
	out=$TK_REPO/.sandbox/rbac/$1.kubeconfig
	mkdir -p "$TK_REPO/.sandbox/rbac"
	server=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
	ca=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
	token=$(k -n "$HNS" create token "$1" --duration=1h)
	(
		umask 077
		cat >"$out" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: kind-tern-kube-dev
    cluster:
      server: $server
      certificate-authority-data: $ca
users:
  - name: $1
    user:
      token: $token
contexts:
  - name: $1@kind-tern-kube-dev
    context:
      cluster: kind-tern-kube-dev
      user: $1
      namespace: $HNS
current-context: $1@kind-tern-kube-dev
EOF
	)
	printf '%s' "$out"
}

# tk-helm-reader reads everything (Secrets included: helm's release
# records) but writes nothing; tk-helm-nosecrets cannot read Secrets.
helm_rbac() {
	k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: { name: tk-helm-reader, namespace: $HNS }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: tk-helm-nosecrets, namespace: $HNS }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: tk-helm-reader, namespace: $HNS }
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: tk-helm-nosecrets, namespace: $HNS }
rules:
  - apiGroups: [""]
    resources: ["configmaps", "services", "pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: tk-helm-reader, namespace: $HNS }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: tk-helm-reader }
subjects: [{ kind: ServiceAccount, name: tk-helm-reader, namespace: $HNS }]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: tk-helm-nosecrets, namespace: $HNS }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: tk-helm-nosecrets }
subjects: [{ kind: ServiceAccount, name: tk-helm-nosecrets, namespace: $HNS }]
EOF
}

scenario_helm_rollback() {
	mkdir -p "$TK_REPO/.sandbox/mutate-it" "$TK_HELM_HOME"
	k delete namespace "$HNS" --ignore-not-found --wait=true >/dev/null 2>&1
	k create namespace "$HNS" >/dev/null || tk_fail "cannot create $HNS"
	helm_up install shop-a "$SHOP"
	helm_up upgrade shop-a "$SHOP" -f "$STAGING"
	tk_begin helm-rollback "$(hlink shop-a 1)"
	tk_expect phase ready
	tk_expect tier typed
	tk_expect token shop-a
	for st in helm-current=ok helm-target=ok helm-latest=ok helm-hooks=ok dry-run=ok diff=changes; do
		tk_expect_has steps "$st"
	done
	tk_expect_has reasons "typed:helm-rollback"
	tk_expect_has segments "modify:Deployment/shop-a-shop"
	tk_expect_has segments "modify:ConfigMap/shop-a-shop-config"
	tk_expect_has live "Deployment/shop-a-shop"
	tk_expect_has view "Recorded change (helm revisions 2 → 1)"
	tk_expect_has view "Against live objects (kubectl diff)"
	tk_expect_has command "HELM_DRIVER=secret"
	expect_release shop-a 2 deployed "Upgrade complete"
	tk_type shop-a
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_release shop-a 3 deployed "Rollback to 1"
	tk_expect_has view "shop-a is now at revision 3 (deployed): Rollback to 1"
	tk_check "audit records the rollback with its revisions" sh -c \
		"grep '\"decision\":\"executed\"' '$TK_W/audit.log' | grep '\"family\":\"helm-rollback\"' | grep -q '\"release\":\"shop-a\",\"revision\":1,\"from_revision\":2'"
	tk_check "the audit line holds no values" sh -c "! grep -q 'staging' '$TK_W/audit.log'"
}

scenario_helm_stale() {
	tk_begin helm-stale "$(hlink shop-a 2)"
	tk_expect phase ready
	tk_note "helm upgrade from the shell between preview and confirm"
	helm_up upgrade shop-a "$SHOP" --reuse-values --set config.mode=stale
	tk_type shop-a
	tk_key enter
	tk_expect phase ready
	tk_expect_has confirm_error "The release changed since the preview (revision 4 deployed, previewed 3 deployed)"
	tk_effects_lacks run "'exec'"
	expect_release shop-a 4 deployed "Upgrade complete"
	tk_check "audit records the refusal" grep -q '"decision":"blocked"' "$TK_W/audit.log"
}

scenario_helm_pending() {
	helm_up install stuck-d "$SHOP"
	h upgrade stuck-d "$SHOP" --set image.tag=does-not-exist --wait --timeout 2m >/dev/null 2>&1 &
	pid=$!
	i=0
	until h history stuck-d -o json 2>/dev/null | grep -q '"pending-upgrade"' &&
		[ "$(k -n "$HNS" get deploy stuck-d-shop -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" = nginx:does-not-exist ]; do
		i=$((i + 1))
		[ "$i" -lt 100 ] || break
		sleep 0.2
	done
	kill -9 "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	expect_release stuck-d 2 pending-upgrade "Preparing upgrade"
	tk_begin helm-pending "$(hlink stuck-d 1)"
	tk_expect phase ready
	tk_expect tier typed
	tk_expect_has reasons "typed:helm-pending"
	tk_expect_has view "pending-upgrade"
	tk_type stuck-d
	tk_key enter
	tk_expect phase done
	tk_expect exec_status 0
	expect_release stuck-d 3 deployed "Rollback to 1"
}

scenario_helm_missing_rev() {
	helm_up install hist-e "$SHOP"
	helm_up upgrade hist-e "$SHOP" --reuse-values --set config.mode=two --history-max 2
	helm_up upgrade hist-e "$SHOP" --reuse-values --set config.mode=three --history-max 2
	hist=$(h history hist-e -o json 2>&1)
	case $hist in
	*'"revision":1,'*) tk_fail "--history-max kept revision 1: $hist" ;;
	*'"revision":3,'*) tk_ok "--history-max dropped revision 1" ;;
	*) tk_fail "hist-e history: $hist" ;;
	esac
	tk_begin helm-missing-rev "$(hlink hist-e 1)"
	tk_expect phase ready
	tk_expect tier blocked
	tk_expect_has steps "helm-current=ok"
	tk_expect_has steps "helm-target=failed"
	tk_expect_has steps "dry-run=failed"
	tk_expect_has reasons "blocked:preview-failed"
	tk_key escape
	tk_expect phase closed
	tk_effects_lacks run "'exec'"
	expect_release hist-e 3 deployed "Upgrade complete"
}

scenario_helm_rbac() {
	helm_rbac
	reader=$(helm_sa_kubeconfig tk-helm-reader)
	nosecrets=$(helm_sa_kubeconfig tk-helm-nosecrets)
	TK_KUBECONFIG=$reader tk_begin helm-rbac-reader \
		"tern-kube://mutate?op=rollback&release=shop-a&revision=3&namespace=$HNS&context=$(url tk-helm-reader@kind-tern-kube-dev)&source=chosen"
	tk_expect phase ready
	tk_expect tier typed
	tk_expect_has steps "helm-current=ok"
	tk_expect_has steps "dry-run=ok"
	tk_note "a reader cannot server-dry-run the live diff: a note, not a failed preview"
	tk_expect_has steps "diff=failed"
	tk_expect_has notes "Live diff unavailable"
	tk_type shop-a
	tk_key enter
	tk_expect phase done
	if [ -n "$S_exec_status" ] && [ "$S_exec_status" != 0 ]; then tk_ok "helm rollback refused by RBAC (exit $S_exec_status)"; else tk_fail "rollback exit '$S_exec_status', want non-zero"; fi
	tk_check "audit records the failure" grep -q '"decision":"failed"' "$TK_W/audit.log"
	expect_release shop-a 4 deployed "Upgrade complete"
	TK_KUBECONFIG=$nosecrets tk_begin helm-rbac-nosecrets \
		"tern-kube://mutate?op=rollback&release=shop-a&revision=3&namespace=$HNS&context=$(url tk-helm-nosecrets@kind-tern-kube-dev)&source=chosen"
	tk_expect phase ready
	tk_expect tier blocked
	tk_expect_has reasons "blocked:preview-failed"
	tk_expect_has steps "helm-current=failed"
	tk_expect_has view "forbidden"
	tk_effects_lacks run "'exec'"
	rm -f "$reader" "$nosecrets"
}

scenario_helm_secret_echo() {
	helm_up install web-e "$WEB" --set auth.password=first-REDACTME --set-string auth.apiToken=tok-REDACTME
	helm_up upgrade web-e "$WEB" --reuse-values --set auth.password=second-REDACTME
	tk_begin helm-secret-echo "$(hlink web-e 1)"
	tk_expect phase ready
	tk_expect_has segments "ConfigMap/web-e-web-config"
	tk_expect_has live "ConfigMap/web-e-web-config"
	tk_expect_has reasons "simple:helm-hooks"
	tk_expect_lacks diff_text "REDACTME"
	tk_expect_lacks live_text "REDACTME"
	tk_expect_lacks view "REDACTME"
	tk_expect_lacks notes "REDACTME"
	tk_key escape
	tk_expect phase closed
}

scenario_helm_cleanup() {
	k delete namespace "$HNS" --ignore-not-found --wait=true >/dev/null 2>&1 || tk_fail "cannot delete $HNS"
	tk_check "$HNS is gone" sh -c "! kubectl --kubeconfig '$KC' --context $CTX get namespace $HNS"
}

ALL="apply_one apply_many diff_modify_cancel stale_file scale restart delete_typed delete_cancel nonexistent
context_drift server_drift rbac_deny_dry_run tiny_timeout cronjob_quick cronjob_quick_no_token guard_roundtrip secret_redaction apply_prompt
guard_disabled guard_namespace_bound label_one label_selector_typed label_conflict_fails annotate_overwrite patch_merge patch_cr_merge
patch_json_typed patch_file_changed_refused undo_previous undo_to_revision undo_single_revision_fails
undo_verify_refuses selection_unchanged selection_added selection_recreated pause_resume cordon_uncordon drain_preflight
drain_pdb_blocked drain_ok edit_request guard_set_image guard_set_noop guard_set_all_mixed guard_set_env_stdin_refused
guard_replace guard_replace_conflict guard_replace_force taint_noexecute_deny taint_prefer_roundtrip
guard_create_secret_masked guard_create_fromdir_fingerprint guard_create_job_from_cronjob guard_create_exists_blocked
guard_run guard_run_attach_preview guard_expose_nodeport
edit_renamed_blocked edit_invalid_approvable helm_rollback helm_stale helm_pending helm_missing_rev helm_rbac
helm_secret_echo helm_cleanup"

for s in ${*:-$ALL}; do
	"scenario_$s"
done

printf '\n%s failure(s)\n' "$TK_FAILS"
[ "$TK_FAILS" = 0 ]

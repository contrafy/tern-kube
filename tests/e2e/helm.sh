# Shared world of the Helm scenarios (50-55), sourced by each of them:
# releases of the fixture charts in tern-test-helm-e2e (plus one in
# tern-test-helm-e2e-b for the namespace scope), installed with the pinned
# .tools/bin/helm and HELM_*_HOME under the sandbox (never the user's
# repositories, registry logins or cache). The first scenario of a run
# builds it from scratch; later ones reuse it while it still looks the way
# helm_world left it. scripts/e2e.sh deletes both namespaces at the end.
#
#   shop-a    shop 0.1.0: install, -f values-staging.yaml, --reuse-values
#             image.tag=1.27.3-alpine (3 revisions, deployed)
#   web-b     web 0.2.0 with password/apiToken, web 0.2.1 canary, then
#             --set typo=1 and a new password (3 revisions; notes, hooks,
#             a Secret)
#   broken-c  failed (the API server rejects service.port=99999)
#   stuck-d   pending-upgrade (upgrade SIGKILLed while waiting)
#   side-g    deployed, in tern-test-helm-e2e-b

HELM_BIN=$E2E_REPO/.tools/bin/helm
HSHOP=$E2E_REPO/tests/fixtures/gitops/helm/chart
HSTAGING=$E2E_REPO/tests/fixtures/gitops/helm/values-staging.yaml
HWEB=$E2E_REPO/tests/fixtures/helm/web
HELM_CONFIG_HOME=$E2E_SB/helm/config
HELM_CACHE_HOME=$E2E_SB/helm/cache
HELM_DATA_HOME=$E2E_SB/helm/data
export HELM_CONFIG_HOME HELM_CACHE_HOME HELM_DATA_HOME

# The config every Helm scenario runs with: the pinned helm, everything
# else default.
HELM_E2E_CONFIG="{\"schema_version\": 1, \"helm\": {\"program\": \"$HELM_BIN\"}}"

# helm_world: build (or reuse) the releases above and point the plugin at
# the pinned helm. Fails the scenario when helm or the cluster misbehaves.
helm_world() {
	[ -x "$HELM_BIN" ] || {
		fail "$HELM_BIN missing; run make bootstrap"
		return 1
	}
	mkdir -p "$E2E_SB/helm"
	[ -f "$E2E_CFG" ] && grep -q "$HELM_BIN" "$E2E_CFG" || set_config "$HELM_E2E_CONFIG"
	# A world left by another run may be older than 15 minutes (stuck-d then
	# reads "stuck?", helm/parse.luau STUCK_AFTER_S) or sit in namespaces that
	# run's cleanup is still deleting.
	[ -f "$E2E_SB/helm/world" ] && helm_world_ok && return 0
	note "building the Helm world in $HNS"
	kc delete namespace "$HNS" "$HNS2" --ignore-not-found --wait=true --timeout=300s >/dev/null 2>&1
	if kc get namespace "$HNS" "$HNS2" -o name 2>/dev/null | grep -q .; then
		fail "$HNS / $HNS2 still terminating after 300 s"
		return 1
	fi
	kc create namespace "$HNS" >/dev/null && kc create namespace "$HNS2" >/dev/null || {
		fail "cannot create $HNS / $HNS2"
		return 1
	}
	helm_shop_a || return 1
	hw install web-b "$HWEB" --set auth.password=hunter2-REDACTME --set-string auth.apiToken=tok-REDACTME || return 1
	"$HELM_BIN" package "$HWEB" --version 0.2.1 --app-version 2.1 -d "$E2E_SB/helm" >/dev/null || {
		fail "cannot package the web chart"
		return 1
	}
	hw upgrade web-b "$E2E_SB/helm/web-0.2.1.tgz" --reuse-values --set config.mode=canary --description "canary rollout" || return 1
	hw upgrade web-b "$E2E_SB/helm/web-0.2.1.tgz" --reuse-values --set typo=1 --set auth.password=hunter3-REDACTME || return 1
	if hm install broken-c "$HSHOP" --set service.port=99999 >/dev/null 2>&1; then
		fail "broken-c installed; expected the API server to reject it"
		return 1
	fi
	helm_stuck_d || return 1
	hw -n "$HNS2" install side-g "$HSHOP" || return 1
	helm_world_ok || {
		fail "the Helm world does not look as built: $(hm list -a -A -o json 2>&1)"
		return 1
	}
	: >"$E2E_SB/helm/world"
}

# hm ARGS...: the pinned helm against kind, release namespace $HNS (a later
# -n wins).
hm() {
	"$HELM_BIN" --kube-context kind-tern-kube-dev --kubeconfig "${E2E_KUBECONFIG:-$E2E_REPO/.sandbox/kubeconfig}" -n "$HNS" "$@"
}

# hw ARGS...: one helm write, quiet; its stderr becomes the failure.
hw() {
	err=$(hm "$@" 2>&1 >/dev/null) || {
		fail "helm $*: $err"
		return 1
	}
}

# helm_shop_a: shop-a from scratch at revision 3 (scenario 53 rolls it back
# and rebuilds it on exit).
helm_shop_a() {
	hm uninstall shop-a --wait >/dev/null 2>&1
	hw install shop-a "$HSHOP" &&
		hw upgrade shop-a "$HSHOP" -f "$HSTAGING" &&
		hw upgrade shop-a "$HSHOP" --reuse-values --set image.tag=1.27.3-alpine
}

# stuck-d: an upgrade killed while helm waits for the new (unpullable)
# image stays pending-upgrade forever.
helm_stuck_d() {
	hw install stuck-d "$HSHOP" || return 1
	"$HELM_BIN" --kube-context kind-tern-kube-dev --kubeconfig "${E2E_KUBECONFIG:-$E2E_REPO/.sandbox/kubeconfig}" -n "$HNS" \
		upgrade stuck-d "$HSHOP" --set image.tag=does-not-exist --wait --timeout 2m >/dev/null 2>&1 &
	pid=$!
	i=0
	until [ "$(jp "$HNS" deployment/stuck-d-shop '{.spec.template.spec.containers[0].image}')" = nginx:does-not-exist ] &&
		hm history stuck-d -o json 2>/dev/null | grep -q '"pending-upgrade"'; do
		i=$((i + 1))
		[ $i -lt 150 ] || {
			kill -9 "$pid" 2>/dev/null
			fail "stuck-d never reached pending-upgrade"
			return 1
		}
		sleep 0.2
	done
	kill -9 "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	return 0
}

# The world is usable as is: every release at its expected revision/status.
helm_world_ok() {
	rows=$(hm list -a -A -o json 2>/dev/null | jq -r --arg a "$HNS" --arg b "$HNS2" \
		'[.[] | select(.namespace == $a or .namespace == $b) | "\(.name)/\(.revision)/\(.status)"] | sort | join(" ")' 2>/dev/null)
	[ "$rows" = "broken-c/1/failed shop-a/3/deployed side-g/1/deployed stuck-d/2/pending-upgrade web-b/3/deployed" ]
}

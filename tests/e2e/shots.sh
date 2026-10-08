# Screenshots for docs/screenshots/m1-<view>-<theme>-<size>.png,
# m2-<view>-<theme>-wide.png and m3-{result,guard}-<theme>-wide.png (sourced
# by scripts/e2e.sh --shots). Every shot is of the live sandbox window with
# the plugin loaded; check each PNG by eye before committing.

shots_dir="$E2E_REPO/docs/screenshots"

shot() { # shot VIEW
	dev shot "m1-$1-$theme-$size" "$shots_dir/m1-$1-$theme-$size.png" >/dev/null || fail "shot $1"
}

shots_views() {
	real
	lens 'kubectl get pods -n tern-test-apps'
	shot pods
	click_text crashloop '.kl-grid .kl-c'
	shot inspector
	click_text Inspect
	shot inspect
	lens 'kubectl get pods -n tern-test-apps'
	click_text '?'
	shot help
	lens 'kubectl get all -n tern-test-apps'
	shot get-all
	lens 'kubectl describe pod crashloop -n tern-test-apps'
	shot describe
	lens 'kubectl get secret app-secret -n tern-test-apps -o yaml'
	shot yaml-secret
	lens 'kubectl top nodes'
	shot top-nodes
	# FAKE: M1 never mutates the cluster; the apply result is a recorded fixture.
	fake real/mutate-create
	lens 'kubectl apply -f mutate/app.yaml -n tern-test-mutate'
	shot apply
	real
}

m2_shot() { # m2_shot VIEW
	dev shot "m2-$1-$theme-wide" "$shots_dir/m2-$1-$theme-wide.png" >/dev/null || fail "shot m2 $1"
}

# Explore (live, real cluster) and a quick-action split; wide only, since the
# block shares the window with the lens pane.
shots_explore() {
	reset_pane
	lens 'kubectl --context kind-kube-lens-dev get deploy -n tern-test-apps'
	click_text web '.kl-grid .kl-c'
	click_text 'Explore live'
	explore_open || return
	xwait 'Object deployment/web'
	m2_shot detail
	xkey R
	xwait 'owner' '[data-role="kube-lens.explore-relations"] *'
	m2_shot relations
	xkey escape
	xkey d
	xwait 'Describe deployment/web'
	m2_shot describe
	xkey escape escape
	xwait 'broken-image' '.kl-grid *'
	m2_shot list
	xkey '?'
	m2_shot help
	xkey escape
	explore_close
	lens 'kubectl get pods -n tern-test-mutate -l app=kl-qa-shell'
	click_text 'kl-qa-shell-*' '.kl-grid .kl-c'
	click_text Logs '[data-role="kube-lens.inspector"] .sf-act'
	E2E_WAIT=15 quick_pane 'kube-lens logs' || return
	E2E_WAIT=20 expect_grid 'ticker: tick' || return
	m2_shot quick-action
	reset_pane
}

m3_shot() { # m3_shot VIEW
	dev shot "m3-$1-$theme-wide" "$shots_dir/m3-$1-$theme-wide.png" >/dev/null || fail "shot m3 $1"
}

# The approve block after a confirmed scale (kl-e2e-web 1 -> 2), and a shell
# guard approval of `kubectl apply -f` for a new ConfigMap in a new tab (short
# cwd so the command line does not wrap; denied after the shot). kl-e2e-*
# objects are deleted afterwards.
shots_m3() {
	reset_pane
	e2e_objects
	lens "kubectl --context kind-kube-lens-dev get deploy kl-e2e-web -n $MNS"
	click_text kl-e2e-web '.kl-grid .kl-c'
	click_text Scale '[data-role="kube-lens.inspector"] .sf-act'
	approve_open && a_input || return
	ctl type 2 >/dev/null
	xkey enter
	a_ready || return
	xkey enter
	a_done || return
	m3_shot result
	xkey escape
	approve_closed
	home=$(ctl state | jq -r '.focused.id')
	mkdir -p "$E2E_SB/m3"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: kl-e2e-guard\n  namespace: %s\ndata:\n  LEVEL: info\n' \
		"$MNS" >"$E2E_SB/m3/kl-e2e-guard.yaml"
	ctl tab new >/dev/null
	sleep 1.5
	sh_line "source '$E2E_REPO/shell/kube-lens.zsh' && cd '$E2E_SB/m3'"
	sh_line clear
	type_line "kubectl apply -f kl-e2e-guard.yaml"
	approve_open && a_ready || return
	m3_shot guard
	xkey escape
	approve_closed
	# Palette apply of a directory: modify kl-e2e-web (replicas 2 -> 3) and
	# kl-e2e-cm, create kl-e2e-applied; the first diff opens expanded.
	mkdir -p "$E2E_SB/m3/app"
	e2e_manifest 3 debug >"$E2E_SB/m3/app/web.yaml"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: kl-e2e-applied\n  namespace: %s\ndata:\n  LEVEL: info\n' \
		"$MNS" >"$E2E_SB/m3/app/new.yaml"
	ctl plugins run plugin.kube-lens.apply >/dev/null
	approve_open && a_input || return
	ctl type app >/dev/null
	xkey enter
	a_ready || return
	xkey tab
	m3_shot diff-expanded
	xkey escape
	approve_closed
	i=0
	while [ "$(ctl state | jq -r '.focused.id')" != "$home" ] && [ $i -lt 4 ]; do
		ctl close >/dev/null
		sleep 0.5
		i=$((i + 1))
	done
	e2e_objects_delete
	reset_pane
}

echo "SHOTS -> $shots_dir"
for theme in light dark; do
	ctl theme light "$theme" >/dev/null
	for size in wide narrow; do
		if [ $size = wide ]; then
			ctl resize 1280 860 >/dev/null
		else
			ctl resize 600 860 >/dev/null
		fi
		sleep 0.8
		shots_views
		if [ $size = wide ]; then
			shots_explore
			shots_m3
		fi
	done
done
ctl theme light light >/dev/null
ctl resize 1280 800 >/dev/null
[ $E2E_FAILED = 0 ]

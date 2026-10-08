# Screenshots for docs/screenshots/m1-<view>-<theme>-<size>.png and
# m2-<view>-<theme>-wide.png (sourced by scripts/e2e.sh --shots). Every shot
# is of the live sandbox window with the plugin loaded; check each PNG by eye
# before committing.

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
		fi
	done
done
ctl theme light light >/dev/null
ctl resize 1280 800 >/dev/null
[ $E2E_FAILED = 0 ]

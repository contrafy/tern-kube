# Screenshots for docs/screenshots/m1-<view>-<theme>-<size>.png,
# m2-<view>-<theme>-wide.png, m3-{result,guard,diff-expanded}-<theme>-wide.png,
# m3b-<view>-<theme>-wide.png and m4-settings-<theme>-wide.png (sourced by
# scripts/e2e.sh --shots). E2E_SHOTS limits the groups (space-separated:
# m1 m2 m3 m3b m4; default all). Every shot is of the live sandbox window with
# the plugin loaded; check each PNG by eye before committing.

shots_dir="$E2E_REPO/docs/screenshots"

shot() { # shot VIEW
	dev shot "m1-$1-$theme-$size" "$shots_dir/m1-$1-$theme-$size.png" >/dev/null || fail "shot $1"
}

shots_views() {
	real
	lens 'kubectl get pods -n tern-test-apps'
	shot pods
	click_text crashloop '.tk-grid .tk-c'
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
	lens 'kubectl --context kind-tern-kube-dev get deploy -n tern-test-apps'
	click_text web '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open || return
	xwait 'Object deployment/web'
	m2_shot detail
	xkey R
	xwait 'owner' '[data-role="tern-kube.explore-relations"] *'
	m2_shot relations
	xkey escape
	xkey d
	xwait 'Describe deployment/web'
	m2_shot describe
	xkey escape escape
	xwait 'broken-image' '.tk-grid *'
	m2_shot list
	xkey '?'
	m2_shot help
	xkey escape
	explore_close
	lens 'kubectl get pods -n tern-test-mutate -l app=tk-qa-shell'
	click_text 'tk-qa-shell-*' '.tk-grid .tk-c'
	click_text Logs '[data-role="tern-kube.inspector"] .sf-act'
	E2E_WAIT=15 quick_pane 'tern-kube logs' || return
	E2E_WAIT=20 expect_grid 'ticker: tick' || return
	m2_shot quick-action
	reset_pane
}

m3_shot() { # m3_shot VIEW
	dev shot "m3-$1-$theme-wide" "$shots_dir/m3-$1-$theme-wide.png" >/dev/null || fail "shot m3 $1"
}

# The approve block after a confirmed scale (tk-e2e-web 1 -> 2), and a shell
# guard approval of `kubectl apply -f` for a new ConfigMap in a new tab (short
# cwd so the command line does not wrap; denied after the shot). tk-e2e-*
# objects are deleted afterwards.
shots_m3() {
	reset_pane
	e2e_objects
	lens "kubectl --context kind-tern-kube-dev get deploy tk-e2e-web -n $MNS"
	click_text tk-e2e-web '.tk-grid .tk-c'
	click_text Scale '[data-role="tern-kube.inspector"] .sf-act'
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
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: tk-e2e-guard\n  namespace: %s\ndata:\n  LEVEL: info\n' \
		"$MNS" >"$E2E_SB/m3/tk-e2e-guard.yaml"
	ctl tab new >/dev/null
	sleep 1.5
	sh_line "source '$E2E_REPO/shell/tern-kube.zsh' && cd '$E2E_SB/m3'"
	sh_line clear
	type_line "kubectl apply -f tk-e2e-guard.yaml"
	approve_open && a_ready || return
	m3_shot guard
	xkey escape
	approve_closed
	# Palette apply of a directory: modify tk-e2e-web (replicas 2 -> 3) and
	# tk-e2e-cm, create tk-e2e-applied; the first diff opens expanded.
	mkdir -p "$E2E_SB/m3/app"
	e2e_manifest 3 debug >"$E2E_SB/m3/app/web.yaml"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: tk-e2e-applied\n  namespace: %s\ndata:\n  LEVEL: info\n' \
		"$MNS" >"$E2E_SB/m3/app/new.yaml"
	ctl plugins run plugin.tern-kube.apply >/dev/null
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

m3b_shot() { # m3b_shot VIEW
	dev shot "m3b-$1-$theme-wide" "$shots_dir/m3b-$1-$theme-wide.png" >/dev/null || fail "shot m3b $1"
}

# Diff vs manifest, drift report, export preview and the git step against a
# throwaway repository (as in scenario 23).
shots_m3b() {
	reset_pane
	gns=tern-test-gitops-ui
	grepo=$E2E_SB/shots-gitops-repo
	rm -rf "$grepo" && mkdir -p "$grepo/apps"
	cp "$E2E_REPO"/tests/e2e/gitops/ui/*.yaml "$grepo/apps/"
	git -C "$grepo" init -q -b main
	git -C "$grepo" -c user.name=e2e -c user.email=e2e@example.invalid add -A
	git -C "$grepo" -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m init
	kc create namespace "$gns" --dry-run=client -o yaml | kc apply -f - >/dev/null
	kc apply -f "$grepo/apps/web.yaml" -f "$grepo/apps/service.yaml" >/dev/null
	kc -n "$gns" patch configmap web-config --type merge -p '{"data":{"mode":"debug"}}' >/dev/null
	kc -n "$gns" create configmap tk-e2e-stray --from-literal=a=b >/dev/null 2>&1
	sh_line "cd '$grepo'"
	lens "kubectl --context kind-tern-kube-dev get configmap web-config -n $gns"
	click_text web-config '.tk-grid .tk-c'
	click_text 'Diff vs manifest' '[data-role="tern-kube.inspector"] .sf-act'
	explore_open && E2E_WAIT=30 xwait "MODIFY" || return
	m3b_shot diff
	xkey ctrl+g
	E2E_WAIT=30 xwait "Drift sources" || return
	xkey enter
	E2E_WAIT=30 xwait "Missing in cluster" || return
	m3b_shot drift
	explore_close
	lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-stray -n $gns"
	click_text tk-e2e-stray '.tk-grid .tk-c'
	click_text 'Explore live' '[data-role="tern-kube.inspector"] .sf-act'
	explore_open && xwait "tk-e2e-stray" || return
	xkey E
	E2E_WAIT=20 xwait "Write 4 files" || return
	m3b_shot export
	explore_close
	kc delete namespace "$gns" --ignore-not-found --wait=false >/dev/null 2>&1
	rm -rf "$grepo"
	sh_line "cd '$E2E_REPO'"
	reset_pane
}

shots_m4() {
	reset_pane
	ctl plugins run plugin.tern-kube.settings >/dev/null
	E2E_WAIT=15 wait_for "the settings block" has "[data-surface='plugin.tern-kube.settings']" || return
	sleep 1
	dev shot "m4-settings-$theme-wide" "$shots_dir/m4-settings-$theme-wide.png" >/dev/null || fail "shot m4 settings"
	ctl key escape >/dev/null
	reset_pane
}

wants() {
	case " ${E2E_SHOTS:-m1 m2 m3 m3b m4} " in *" $1 "*) true ;; *) false ;; esac
}

echo "SHOTS -> $shots_dir"
for theme in light dark; do
	ctl theme light "$theme" >/dev/null
	for size in wide narrow; do
		if [ $size = wide ]; then
			ctl resize 1280 860 >/dev/null
		else
			wants m1 || continue
			ctl resize 600 860 >/dev/null
		fi
		sleep 0.8
		wants m1 && shots_views
		if [ $size = wide ]; then
			wants m2 && shots_explore
			wants m3 && shots_m3
			wants m3b && shots_m3b
			wants m4 && shots_m4
		fi
	done
done
ctl theme light light >/dev/null
ctl resize 1280 800 >/dev/null
[ $E2E_FAILED = 0 ]

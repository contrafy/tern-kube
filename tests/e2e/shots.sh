# Screenshots for docs/screenshots/m1-<view>-<theme>-<size>.png,
# m2-<view>-<theme>-wide.png, m3-{result,guard,diff-expanded}-<theme>-wide.png,
# m3b-<view>-<theme>-wide.png, m4-settings-<theme>-wide.png,
# t1-{label-diff,drain-preview,undo-diff,edit-approve}-dark-wide.png,
# t2-{logs,logs-multi,logs-context,events-lens,explore-events,explore-logs}-dark-wide.png,
# t3-{releases,values-defaults,revision-diff,rollback,lens-chip}-dark-wide.png
# and m6-compare-{object,list,drift}-dark-wide.png
# (sourced by scripts/e2e.sh --shots). E2E_SHOTS limits the groups
# (space-separated: m1 m2 m3 m3b m4 t1 t2 t3 m6; default all; m6 needs
# E2E_MC=1). Every shot is of the live headless sandbox session with the
# plugin loaded, at 1280x800 (narrow: 600x800) CSS px and scale 2, so wide
# PNGs are 2560x1600; check each PNG by eye before committing.

shots_dir="$E2E_REPO/docs/screenshots"

# snap NAME: shoot docs/screenshots/NAME.png. A headless session never fades
# a toast, so a visible one fails the shot instead of landing in the docs.
snap() {
	lacks '.toast' || fail "toast \"$(alltext '.toast')\" in $1"
	dev shot "$1" "$shots_dir/$1.png" >/dev/null || fail "shot $1"
}

# xclose: close the Explore pane outright, then give the left-most pane the
# keyboard (as reset_pane). Esc at the Explore root leaves an "esc again to
# close" toast that a headless session never fades, so later shots would
# carry it. A kubectl edit split keeps the keyboard after its approval, so
# look left, then right, for the Explore pane first.
xclose() {
	has "$EX" || return 0
	for _dir in left right; do
		x_focused && break
		ctl focus "$_dir" >/dev/null
	done
	if x_focused; then
		ctl close >/dev/null
		sleep 0.4
		ctl click 30 600 >/dev/null
	else
		explore_close_all
	fi
	E2E_WAIT=5 wait_for "Explore to close" lacks "$EX"
}

x_focused() {
	case $(focused_title) in *"Tern Kube Explore"*) true ;; *) false ;; esac
}

shot() { # shot VIEW
	snap "m1-$1-$theme-$size"
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
	snap "m2-$1-$theme-wide"
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
	xwait 'broken-image' "$XT *"
	m2_shot list
	xkey '?'
	m2_shot help
	xkey escape
	xclose
	lens 'kubectl get pods -n tern-test-mutate -l app=tk-qa-shell'
	click_text 'tk-qa-shell-*' '.tk-grid .tk-c'
	click_text Logs '[data-role="tern-kube.inspector"] .sf-act'
	E2E_WAIT=15 quick_pane 'tern-kube logs' || return
	E2E_WAIT=20 expect_grid 'ticker: tick' || return
	m2_shot quick-action
	reset_pane
}

m3_shot() { # m3_shot VIEW
	snap "m3-$1-$theme-wide"
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
	snap "m3b-$1-$theme-wide"
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
	xclose
	lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-stray -n $gns"
	click_text tk-e2e-stray '.tk-grid .tk-c'
	click_text 'Explore live' '[data-role="tern-kube.inspector"] .sf-act'
	explore_open && xwait "tk-e2e-stray" || return
	xkey E
	E2E_WAIT=20 xwait "Write 4 files" || return
	m3b_shot export
	xclose
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
	snap "m4-settings-$theme-wide"
	ctl key escape >/dev/null
	reset_pane
}

t1_shot() { # t1_shot VIEW
	snap "t1-$1-$theme-wide"
}

# Previews of the 0.2.0 verbs, nothing confirmed: a label diff from the lens
# chip, then from Explore (approve pane zoomed) a drain blocked by a
# PodDisruptionBudget, a rollout undo diff and a kubectl edit approval
# (scripted KUBE_EDITOR, denied after the shot). As scenarios 24-28.
shots_t1() {
	reset_pane
	e2e_objects
	kc -n "$MNS" set image deploy/tk-e2e-web web=registry.k8s.io/pause:3.9 >/dev/null
	kc -n "$MNS" rollout status deploy/tk-e2e-web --timeout=60s >/dev/null
	kc -n "$MNS" create pdb tk-e2e-pdb --selector=app=tk-e2e-web --min-available=1 >/dev/null
	ins='[data-role="tern-kube.inspector"] .sf-act'
	lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-cm -n $MNS"
	click_text tk-e2e-cm '.tk-grid .tk-c'
	click_text Label "$ins"
	approve_open && a_input || return
	ctl type '"tier=gold team=payments"' >/dev/null
	xkey enter
	a_ready || return
	t1_shot label-diff
	xkey escape
	approve_closed

	node=$(kc get nodes -o jsonpath='{.items[0].metadata.name}')
	lens "kubectl --context kind-tern-kube-dev get nodes"
	click_text "$node" '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open && xwait "Object node/$node" || return
	xkey D
	approve_open && a_input || return
	xkey cmd+a
	ctl type '"--ignore-daemonsets --timeout=4m --pod-selector=app=tk-e2e-web"' >/dev/null
	xkey enter
	E2E_WAIT=40 a_ready || return
	ctl zoom >/dev/null
	sleep 0.8
	t1_shot drain-preview
	xkey escape
	approve_closed
	xclose
	kc -n "$MNS" delete pdb tk-e2e-pdb --ignore-not-found >/dev/null

	lens "kubectl --context kind-tern-kube-dev get deploy tk-e2e-web -n $MNS"
	click_text tk-e2e-web '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open && xwait 'Object deployment/tk-e2e-web' || return
	xkey U
	approve_open && a_ready || return
	ctl zoom >/dev/null
	sleep 0.8
	t1_shot undo-diff
	xkey escape
	approve_closed
	xclose

	printf '%s\n' "sed 's/^  LEVEL: .*/  LEVEL: debug/' \"\$1\" >\"\$1.new\" && cat \"\$1.new\" >\"\$1\" && rm -f \"\$1.new\"" \
		>"$E2E_SB/edit-script"
	lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-cm -n $MNS"
	click_text tk-e2e-cm '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open && xwait 'Object configmap/tk-e2e-cm' || return
	xkey e
	approve_open && a_ready || return
	ctl zoom >/dev/null
	sleep 0.8
	t1_shot edit-approve
	xkey escape
	approve_closed
	sleep 2
	xclose
	rm -f "$E2E_SB/edit-script"
	e2e_objects_delete
	reset_pane
}

t2_shot() { # t2_shot VIEW
	snap "t2-$1-$theme-wide"
}

# The logs lens on tk-logmix (tern-test-logs), a 25 000-line fake log's
# context jump and the events views of tern-test-apps, as scenarios 40, 41,
# 44, 46, 47 and 49. Nothing mutates.
shots_t2() {
	reset_pane
	pod=$(logmix_pod) || {
		fail "no tk-logmix pod in $LNS"
		return
	}
	lens "kubectl logs -n $LNS $pod -c app"
	logs_native || return
	if has '[data-role="tern-kube.pages"]'; then
		click_text 1 '[data-role="tern-kube.pages"] .sf-act' || return
	fi
	click_text 'server started*' '.tk-grid .tk-c' || return
	top
	t2_shot logs

	lens "kubectl logs -n $LNS -l app=tk-logmix --all-containers --prefix --timestamps --tail=6"
	logs_native || return
	click_text 'By time' '[data-role="tern-kube.chips"] .sf-act' || return
	t2_shot logs-multi

	# FAKE: no kind container logs 25 000 lines on demand (as scenario 44).
	dir=$E2E_SB/fake-logs
	mkdir -p "$dir"
	awk 'BEGIN {
		for (i = 1; i <= 25000; i++) {
			if (i % 997 == 0) printf "{\"level\":\"error\",\"msg\":\"request %d failed\",\"code\":500}\n", i
			else if (i % 13 == 0) printf "level=warn msg=\"slow request %d\" dur=2.1s\n", i
			else printf "{\"level\":\"info\",\"msg\":\"request %d\",\"path\":\"/api\"}\n", i
		}
	}' >"$dir/logs_big-0.txt"
	sh_line "tk_fake '$dir'"
	E2E_WAIT=60 lens 'kubectl logs big-0'
	logs_native || return
	click_text 'First error' '[data-role="tern-kube.chips"] .sf-act' || return
	E2E_WAIT=5 wait_for "the context view" has '[data-role="tern-kube.context"]' || return
	top
	t2_shot logs-context
	real

	lens "kubectl events -n tern-test-apps"
	native || return
	t2_shot events-lens

	lens "kubectl --context kind-tern-kube-dev get pods -n tern-test-apps"
	click_text crashloop '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open || return
	xwait 'Object pod/crashloop'
	xkey escape
	xwait 'crashloop' "$XT *"
	xkey v
	xwait "events · ns tern-test-apps"
	t2_shot explore-events
	xclose

	lens "kubectl --context kind-tern-kube-dev get pods -n $LNS -l app=tk-logmix"
	click_text "$pod" '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open || return
	xwait "Object pod/$pod"
	xkey L
	xwait "Logs pod/$pod"
	xwait '--tail=500' '[data-role="tern-kube.logs-summary"] *'
	xkey ]
	t2_shot explore-logs
	xclose
	reset_pane
}

t3_shot() { # t3_shot VIEW
	snap "t3-$1-$theme-wide"
}

# t3_release DEPLOYMENT: Explore of a Helm world Deployment, H opens its
# release.
t3_release() {
	lens "kubectl --context kind-tern-kube-dev get deploy -n $HNS"
	native
	click_text "$1" '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open || return 1
	xwait "Object deployment/$1"
	xkey H
	xwait 'rev '
}

# The Helm views on the tests/e2e/helm.sh world, as scenarios 50-54: the
# releases route, shop-a's values against the chart defaults, web-b's
# masked revision diff, a rollback preview (cancelled) and the lens chip.
shots_t3() {
	. "$E2E_REPO/tests/e2e/helm.sh"
	helm_world || return
	reset_pane
	lens "kubectl --context kind-tern-kube-dev get deploy -n $HNS"
	native
	click_text web-b-web '.tk-grid .tk-c'
	click_text 'Explore live'
	explore_open || return
	xwait 'Object deployment/web-b-web'
	xkey escape
	xwait 'web-b-web' "$XT *"
	xkey :
	xwait 'Kinds'
	ctl type helm >/dev/null
	xwait 'Helm releases'
	xkey enter
	xwait '4 releases'
	t3_shot releases
	xclose

	t3_release shop-a-shop || return
	xkey v
	xwait 'Values shop-a (changed)'
	# changed mode: each overridden key beside its chart default.
	E2E_WAIT=20 xwait 'image.tag' "$XT *" || return
	t3_shot values-defaults
	xclose

	t3_release web-b-web || return
	xkey h
	xwait '3 revisions'
	xkey G =
	xwait 'Diff web-b rev 1..3'
	E2E_WAIT=20 xwait 'MODIFY Secret' || return
	t3_shot revision-diff
	xclose

	t3_release shop-a-shop || return
	xkey h
	xwait '3 revisions'
	xkey G ctrl+r
	approve_open || return
	E2E_WAIT=40 a_ready || return
	ctl zoom >/dev/null
	sleep 0.8
	t3_shot rollback
	xkey escape
	approve_closed
	xclose

	lens "kubectl --context kind-tern-kube-dev describe deploy shop-a-shop -n $HNS"
	native
	t3_shot lens-chip
	reset_pane
}

m6_shot() { # m6_shot VIEW
	snap "m6-compare-$1-$theme-wide"
}

# Compare across contexts on both kind clusters, as scenarios 70, 73 and 76:
# tkm-web's pairwise diff, the Deployments list matrix of tern-test-mc and
# the drift matrix of tests/integration/manifests/compare/source in a
# throwaway git repository. Read-only.
shots_m6() {
	if [ "${E2E_MC:-0}" != 1 ]; then
		echo "skip m6 shots (no peer cluster: scripts/cluster.sh create-peer, then E2E_MC=1)"
		return 0
	fi
	. "$E2E_REPO/tests/e2e/compare.sh"
	reset_pane
	mc_object "$MCA" deploy tkm-web deployment || return
	mc_pick_first || return
	E2E_WAIT=20 xwait differs '[data-role="tern-kube.compare-status"] *' || return
	m6_shot object
	xclose

	mc_object "$MCA" deploy tkm-web deployment || return
	xkey escape
	xwait tkm-api "$XT *" || return
	mc_pick_first || return
	E2E_WAIT=20 xwait changed "[data-role='tern-kube.compare-matrix'] *" || return
	m6_shot list
	xclose

	m6repo=$E2E_SB/m6-repo
	rm -rf "$m6repo"
	mkdir -p "$m6repo/apps"
	cp "$E2E_REPO/tests/integration/manifests/compare/source/app.yaml" "$m6repo/apps/"
	git -C "$m6repo" init -q -b main
	git -C "$m6repo" -c user.name=e2e -c user.email=e2e@example.invalid add -A
	git -C "$m6repo" -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m init
	sh_line "cd '$m6repo'"
	mc_object "$MCA" deploy tkm-web deployment || return
	xkey ctrl+g
	E2E_WAIT=30 xwait "Drift sources" || return
	xkey enter
	E2E_WAIT=30 xwait "Drift of" || return
	xkey x
	E2E_WAIT=15 xwait "All contexts (2)" "[data-role='tern-kube.compare-picker'] *" || return
	xkey G enter
	E2E_WAIT=40 xwait "changed +4 -3" || return
	m6_shot drift
	xclose
	sh_line "cd '$E2E_REPO'"
	rm -rf "$m6repo"
	reset_pane
}

wants() {
	case " ${E2E_SHOTS:-m1 m2 m3 m3b m4 t1 t2 t3 m6} " in *" $1 "*) true ;; *) false ;; esac
}

echo "SHOTS -> $shots_dir"
for theme in light dark; do
	ctl theme light "$theme" >/dev/null
	for size in wide narrow; do
		if [ $size = wide ]; then
			w=1280
		else
			wants m1 || continue
			w=600
		fi
		viewport_size $w 800 || {
			fail "the viewport stays $(viewport), not ${w}x800"
			break 2
		}
		sleep 0.8
		wants m1 && shots_views
		if [ $size = wide ]; then
			wants m2 && shots_explore
			wants m3 && shots_m3
			wants m3b && shots_m3b
			wants m4 && shots_m4
			if [ $theme = dark ]; then
				wants t1 && shots_t1
				wants t2 && shots_t2
				wants t3 && shots_t3
				wants m6 && shots_m6
			fi
		fi
	done
done
ctl theme light light >/dev/null
viewport_size 1280 800 || fail "the viewport stays $(viewport), not 1280x800"
make -C "$E2E_REPO" shots-optimize || fail "shots-optimize"
[ $E2E_FAILED = 0 ]

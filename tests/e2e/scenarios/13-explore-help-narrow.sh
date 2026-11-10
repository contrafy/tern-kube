# Live: help card, Explore live link (real kubectl in the daemon), narrow
# window hides low-priority columns.
lens 'kubectl get pods -n tern-test-apps'
native
click_text '?'
has '[data-role="tern-kube.help"]' || fail "help card did not open"
click_text '? hide help'
lacks '[data-role="tern-kube.help"]' || fail "help card did not close"
click_text db-0 '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object pod/db-0'
contains "explore target" "$(xtext '[data-role="tern-kube.explore-header"] *')" "ns tern-test-apps"
explore_close
if window_size 500 800; then
	top
	eq "narrow headers" "$(texts '.tk-grid .tk-h')" '["NAME","READY","STATUS"]'
	window_size 1280 800 || true
else
	# The tiers are window-width @media rules (Tern has no container
	# queries), so a window that keeps its size cannot show them: check
	# what the narrowest rule keeps instead.
	note "window stays $(viewport): checking the narrow column tier, not the narrow layout"
	eq "narrow headers" "$(texts '.tk-grid .tk-h.tk-p0')" '["NAME","READY","STATUS"]'
	contains "narrow column count" "$(ctl tree '.tk-grid' | jq -r '.nodes[0].class')" "tk-c-3"
fi

# Live: the Explore `:` command prompt (read-only). `:` focuses the prompt;
# kinds and aliases (deploy, po, svc, cm and the CRD short name wd from
# discovery) jump to their lists, `ns NAME` scopes, `ctx NAME` picks a
# kubeconfig context (chosen, unconfirmed), `helm` (when helm is found) and
# `events` open their roots, an unknown word toasts and keeps the prompt,
# tab completes, esc goes back. A second Explore block's `:` reads the
# host's discovery cache: no new api-resources run.
ns=tern-test-apps

# prompt TEXT: open the prompt, type TEXT, run it. `tern ctl` re-splits its
# words: TEXT goes quoted so `ns NAME` keeps its space.
prompt() {
	xkey :
	xwait 'Kinds'
	ctl type "\"$1\"" >/dev/null
	xkey enter
}

kinds_runs() {
	sleep 1
	grep 'tern-kube explore.run' "$(daemon_log)" | grep -c 'kinds|'
}

lens "kubectl --context kind-tern-kube-dev get pods -n $ns"
native
click_text db-0 '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object pod/db-0'
xkey escape
xwait 'crashloop' "$XT"

# `:` opens the picker with the prompt focused: commands first, then kinds.
xkey :
xwait 'context picker / switch'
contains "prompt placeholder" "$(alltext "$EX input" | tr '\n' ' ')$(xtext)" "ctx NAME"
eq "first row is the ctx command" "$(hcol 1 | jq -r '.[0]')" "ctx …"
contains "dock names the prompt keys" "$(xtext)" "tab completes"
xkey escape
xwait 'crashloop' "$XT"

prompt deploy
xwait 'web' "$XT"
contains "deploy lists deployments" "$(xtext '[data-role="tern-kube.breadcrumb"] *')" "deployments"
prompt po
xwait 'crashloop' "$XT"
prompt svc
xwait 'web' "$XT"
contains "svc lists services" "$(xtext '[data-role="tern-kube.breadcrumb"] *')" "services"
prompt cm
xwait 'kube-root-ca.crt' "$XT"

# A CRD short name comes from discovery, scoped by the prompt's argument.
prompt 'wd tern-test-crd'
xwait 'gizmo' "$XT"
contains "wd lists widgets" "$(xtext '[data-role="tern-kube.breadcrumb"] *')" "widgets.lens.example.com"
contains "wd NS scopes" "$(xtext)" "ns tern-test-crd"

# ns NAME: the scope chip follows.
prompt "ns $ns"
xwait "ns $ns"

# ctx NAME: an exact kubeconfig context is a choice, not a confirmation.
prompt 'ctx kind-tern-kube-dev'
xwait '(chosen)'
excludes "ctx leaves the target unconfirmed" "$(xtext '[data-role="tern-kube.explore-header"] *')" " confirmed"
contains "Confirm target offered" "$(xtext)" "Confirm target"
# ns and ctx keep the kind (widgets): back to the pods of the namespace.
prompt "po $ns"
xwait 'crashloop' "$XT"

# helm: the releases root, or the helm-not-found toast without helm.
prompt helm
sleep 1
if printf '%s' "$(alltext '.toast span')" | grep -q 'helm not found'; then
	note "skipped :helm: helm not found"
	xkey escape
else
	xwait 'releases'
	prompt po
fi
xwait 'crashloop' "$XT"

# events: the namespace timeline at the root.
prompt events
xwait "events · ns $ns"
xkey escape
explore_close

lens "kubectl --context kind-tern-kube-dev get pods -n $ns"
native
click_text db-0 '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object pod/db-0'
xkey escape
xwait 'crashloop' "$XT"
# A second block: discovery comes from the host's in-memory cache.
runs=$(kinds_runs)

# An unknown word: a toast, and the prompt stays open with the text.
prompt xyz
sleep 0.5
contains "unknown word toast" "$(alltext '.toast span')" 'No kind or command matches "xyz"'
xwait 'Kinds'
xkey escape
xwait 'crashloop' "$XT"

# tab completes the first word to the highlighted row's canonical name.
xkey :
xwait 'Kinds'
ctl type dep >/dev/null
xkey tab
xwait 'deployments.apps'
contains "tab completes" "$(alltext "$EX input" | tr '\n' ' ')$(xtext)" "deployments.apps"
xkey escape
xwait 'crashloop' "$XT"

# The CRD is known at once from the cached discovery; still no new run.
xkey :
xwait 'Kinds'
ctl type wd >/dev/null
xwait 'widgets.lens.example.com'
eq "second block's : runs no api-resources" "$(kinds_runs)" "$runs"
xkey escape
explore_close

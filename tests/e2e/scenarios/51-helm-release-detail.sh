# Live: web-b's release route (tests/e2e/helm.sh, read-only). H on a
# Helm-managed object opens its release: header, values summary with the
# unknown key from --set typo=1, hooks summary, notes. v opens the values
# (changed mode; password and apiToken masked, typo flagged), v cycles the
# five modes; N notes, K hooks with their last run, M manifest: the Secret
# and the ConfigMap's DSN echo of the password are masked everywhere.
. "$E2E_REPO/tests/e2e/helm.sh"
helm_world || return

# No view of the release may show a fake secret (*-REDACTME) unmasked.
no_secrets() {
	excludes "$1 masks secrets" "$(xtext)" "REDACTME"
}

lens "kubectl --context kind-tern-kube-dev get deploy -n $HNS"
native
click_text web-b-web '.tk-grid .tk-c'
click_text 'Explore live'
explore_open || return
xwait 'Object deployment/web-b-web'
xkey H
xwait 'rev 3 of 3'
E2E_WAIT=20 xwait 'unknown key' || return
head=$(xtext '[data-role="tern-kube.helm-head"] *')
contains "release name" "$head" "web-b"
contains "chart version" "$head" "web-0.2.1"
contains "app version" "$head" "app 2.1"
contains "status badge" "$(texts "$EX [data-role='tern-kube.helm-head'] .sf-badge")" "deployed"
contains "unknown key warning" "$(xtext '[data-role="tern-kube.helm-values-summary"] *')" "1 unknown key (typo? the chart never reads it)"
contains "hooks summary" "$(xtext '[data-role="tern-kube.helm-hooks-summary"] *')" "Hooks"
contains "notes excerpt masked" "$(xtext '[data-role="tern-kube.helm-notes"] *')" "API token: <redacted>"
no_secrets "release"

# v: values in changed mode; the typo is flagged, secrets masked.
xkey v
xwait 'Values web-b (changed)'
E2E_WAIT=20 xwait 'unknown-key' '.tk-grid *' || return
eq "changed rows" "$(hcol 1 5)" '["auth.apiToken","auth.password","config.mode","typo"]'
eq "typo state" "$(hcol 2 5 | jq -r '.[3]')" "unknown-key"
eq "password masked" "$(hcol 4 5 | jq -r '.[1]')" "<redacted>"
contains "suspect defaults banner" "$(xtext)" "may include values reused from an earlier revision"
no_secrets "values (changed)"
for mode in user computed defaults diff changed; do
	xkey v
	xwait "Values web-b ($mode)"
	no_secrets "values ($mode)"
done

# N: notes, the token echo masked.
xkey N
xwait 'Notes web-b'
contains "notes text" "$(xtext '[data-role="tern-kube.helm-notes"] *')" "web-b serves on port 80 in $HNS."
contains "notes token masked" "$(xtext '[data-role="tern-kube.helm-notes"] *')" "API token: <redacted>"
no_secrets "notes"

# K: hooks with events and the last run of revision 3.
xkey K
xwait 'Hooks web-b'
hooks=$(xtext '[data-role="tern-kube.helm-hook"] *')
contains "pre-upgrade hook" "$hooks" "ConfigMap web-b-web-pre-upgrade"
contains "hook events" "$hooks" "pre-upgrade, pre-rollback"
contains "hook last run" "$hooks" "Succeeded"
contains "hook that never ran" "$hooks" "never ran in this revision"

# M: manifest; the Secret's values and the ConfigMap's DSN are masked.
xkey M
xwait 'Manifest web-b'
docs=$(xtext '[data-role="tern-kube.helm-doc"] *')
contains "Secret in the manifest" "$docs" "web-b-web-auth"
contains "Secret password masked" "$docs" "password: '<redacted>'"
contains "DSN echo masked" "$docs" "postgres://app:<redacted>@db:5432/app"
excludes "no mask sizes" "$docs" "bytes>"
no_secrets "manifest"
explore_close_all

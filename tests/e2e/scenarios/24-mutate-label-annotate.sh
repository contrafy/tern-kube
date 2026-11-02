# Label and Annotate from lens inspector chips on a ConfigMap
# (tern-test-mutate/tk-e2e-cm): the label preview is a before/after object
# diff of a server dry run; cancel leaves the object unlabeled, confirm
# labels it. Annotate with --overwrite of an existing value and of the
# last-applied configuration is typed: an inexact token never annotates.
# tk-e2e-* objects are deleted at the end.
trap e2e_objects_delete EXIT
e2e_objects
INS='[data-role="tern-kube.inspector"] .sf-act'

lens "kubectl --context kind-tern-kube-dev get configmap tk-e2e-cm -n $MNS"
native
click_text tk-e2e-cm '.tk-grid .tk-c'
eq "mutation chips" "$(texts '[data-role="tern-kube.mutate"]')" '["Delete","Label","Annotate","Patch"]'
contains "edit chip" "$(texts "$INS")" '"Edit"'

# Label: prompt, object diff, cancel -> no label.
click_text Label "$INS"
approve_open || return
a_input || return
contains "label prompt" "$(atext)" "Labels for configmap/tk-e2e-cm: KEY=VALUE sets, KEY- removes"
ctl type tier=gold >/dev/null
xkey enter
a_ready || return
contains "object diff header" "$(atext)" "MODIFY ConfigMap tern-test-mutate/tk-e2e-cm"
contains "added label in the diff" "$(atext)" "tier: gold"
contains "count badge" "$(atext)" "1 to label"
xkey escape
approve_closed || return
eq "cancelled label" "$(jp $MNS cm/tk-e2e-cm '{.metadata.labels.tier}')" ""

# Label again, confirm (simple tier) -> labeled.
click_text Label "$INS"
approve_open || return
a_input || return
ctl type tier=gold >/dev/null
xkey enter
a_ready || return
xkey enter
a_done || return
contains "exit status" "$(atext)" "exit 0"
eq "confirmed label" "$(jp $MNS cm/tk-e2e-cm '{.metadata.labels.tier}')" gold
xkey escape
approve_closed || return

# Annotate a new key (simple), then overwrite it together with the
# last-applied configuration (typed).
click_text Annotate "$INS"
approve_open || return
a_input || return
ctl type team=a >/dev/null
xkey enter
a_ready || return
xkey enter
a_done || return
eq "annotated" "$(jp $MNS cm/tk-e2e-cm '{.metadata.annotations.team}')" a
xkey escape
approve_closed || return

click_text Annotate "$INS"
approve_open || return
a_input || return
ctl type '"team=b kubectl.kubernetes.io/last-applied-configuration={} --overwrite"' >/dev/null
xkey enter
a_ready || return
contains "typed tier" "$(atext)" "Typed confirm"
contains "overwrite counted" "$(atext)" "2 existing value(s) change"
contains "last-applied reason" "$(atext)" "Rewrites the last-applied configuration"
ctl type tk-e2e-c >/dev/null
xkey enter
sleep 1
eq "inexact token keeps the annotation" "$(jp $MNS cm/tk-e2e-cm '{.metadata.annotations.team}')" a
xkey escape
approve_closed || return
eq "cancelled overwrite keeps the annotation" "$(jp $MNS cm/tk-e2e-cm '{.metadata.annotations.team}')" a

click_text Annotate "$INS"
approve_open || return
a_input || return
ctl type '"team=b kubectl.kubernetes.io/last-applied-configuration={} --overwrite"' >/dev/null
xkey enter
a_ready || return
ctl type tk-e2e-cm >/dev/null
xkey enter
a_done || return
eq "overwritten annotation" "$(jp $MNS cm/tk-e2e-cm '{.metadata.annotations.team}')" b
xkey escape
approve_closed

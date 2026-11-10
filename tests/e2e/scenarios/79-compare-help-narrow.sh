# Live, two clusters (E2E_MC=1): help lists the compare keys (x, [ ], f);
# the matrix shows short context labels with a legend at any width (the
# block's columns do not follow its split, so Explore never asks for them).
. "$E2E_REPO/tests/e2e/compare.sh"

mc_object "$MCA" deploy tkm-web deployment || return
xkey escape
xwait 'tkm-api' "$XT *" || return
mc_pick_first || return
E2E_WAIT=20 wait_for "the list matrix" has "$EX [data-role='tern-kube.compare-matrix']" || return
xkey '?'
help=$(alltext "[data-role='tern-kube.explore-layer'] *" | tr '\n' ' ')
contains "help: x" "$help" "Compare across contexts: the list in view"
contains "help: [ ]" "$help" "Compare: previous / next other context"
contains "help: f" "$help" "Compare: show all objects / only what differs"
xkey escape

top
legend=$(xtext "[data-role='tern-kube.compare-legend'] *")
contains "legend maps short labels" "$legend" "dev = kind-tern-kube-dev"
contains "legend maps the peer" "$legend" "dev2 = kind-tern-kube-dev2"
excludes "columns use short labels" "$(xtext "[data-role='tern-kube.compare-matrix'] .tk-h")" "kind-tern-kube-dev2"
explore_close

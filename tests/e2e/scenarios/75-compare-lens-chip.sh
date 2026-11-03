# Live, two clusters (E2E_MC=1): the lens inspector chip "Compare across
# contexts" opens Explore on the context picker for the selected object.
. "$E2E_REPO/tests/e2e/compare.sh"

mc_lens "$MCA" deploy
click_text tkm-web '.tk-grid .tk-c' || return
click_text 'Compare across contexts' '[data-role="tern-kube.inspector"] .sf-act' || return
explore_open || return
E2E_WAIT=15 xwait "$MCB" "[data-role='tern-kube.compare-picker'] *" || return
contains "picker for the selected object" "$(xtext)" "tkm-web"
xkey enter
E2E_WAIT=20 xwait "differs" '[data-role="tern-kube.compare-status"] *' || return
explore_close

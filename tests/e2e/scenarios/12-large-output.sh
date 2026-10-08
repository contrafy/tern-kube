# FAKE: a read-only kind cluster has no 1000 pods or 16 MiB listings, so the
# recorded synthetic 1000-row fixture and the fake's row generator stand in.
fake synthetic/rows-1000
lens 'kubectl get pods -A -o wide'
native
ctl scroll -100000 >/dev/null
sleep 0.3
eq "page chips" "$(texts '[data-role="kube-lens.pages"] .sf-act')" '["1-500","501-1000"]'
xy=$(ctl tree '[data-role="kube-lens.pages"] .sf-act' | jq -r '[.nodes[]? | select(.text == "501-1000")][0].rect | "\(.[0] + .[2] / 2) \(.[1] + .[3] / 2)"')
# shellcheck disable=SC2086
ctl click $xy >/dev/null
sleep 0.6
ctl scroll -100000 >/dev/null
sleep 0.3
contains "second page" "$(alltext '[data-role="kube-lens.pages"] .sf-text')" "Rows 501-1000 of 1000"

fake ""
sh_line 'export KUBE_LENS_FAKE_ROWS=200000'
mark=$(log_lines)
start=$(date +%s)
E2E_WAIT=30 lens 'kubectl get pods'
took=$(($(date +%s) - start))
raw
[ $took -le 15 ] || fail "200000-row output took ${took}s with the lens"
tail -n +"$((mark + 1))" "$(daemon_log)" | grep -q 'overflow=true' || fail "no overflow logged"

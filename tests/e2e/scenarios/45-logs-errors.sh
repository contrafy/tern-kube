# Live: when kubectl prints only its own error the block stays raw, exactly
# what the terminal shows (plan 4.6): a missing pod, a bad container,
# --previous of a container that never restarted, too many follow streams.
# The crash-looping container has a previous instance: native.
pod=$(logmix_pod) || {
	fail "no tk-logmix pod in $LNS"
	return
}
lens "kubectl logs -n $LNS nopod"
raw
lens "kubectl logs -n $LNS $pod -c nope"
raw
lens "kubectl logs -n $LNS $pod -p -c app"
raw
# 2 pods x 3 containers = 6 streams > kubectl's default --max-log-requests 5.
lens "kubectl logs -n $LNS -f -l app=tk-logmix --all-containers --prefix"
raw
lens "kubectl logs -n $LNS $pod -p -c crashy"
logs_native || return
contains "the previous instance's panic" "$(ltext '.tk-grid *')" "panic: runtime error"

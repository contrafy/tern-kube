# Live: describe pod.
lens 'kubectl describe pod db-0 -n tern-test-apps'
native
body=$(alltext '[data-role="tern-kube.describe"] *')
contains "describe" "$body" db-0
contains "describe" "$body" Conditions

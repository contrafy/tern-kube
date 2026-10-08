# Live: get all, one grid per kind with kind headings.
lens 'kubectl get all -n tern-test-apps'
native
for k in Pod Service DaemonSet Deployment ReplicaSet StatefulSet; do
	contains "kind headings" "$(alltext '[data-role="kube-lens.kind"] *')" "$k"
done

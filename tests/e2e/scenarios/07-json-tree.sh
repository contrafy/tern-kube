# Live: -o json is ours (not the built-in), object tree on Inspect.
lens 'kubectl get pods -n tern-test-apps -o json'
native
contains "header" "$(alltext '[data-role="tern-kube.header"] .sf-text')" "-o json"
click_text db-0 '.tk-grid .tk-c'
click_text Inspect
has '[data-role="tern-kube.inspect"] .sf-tree' || fail "Inspect shows no object tree"
contains "tree" "$(alltext '[data-role="tern-kube.inspect"] .sf-tree *')" apiVersion

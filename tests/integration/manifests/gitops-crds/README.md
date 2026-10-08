# Vendored GitOps CRDs

Upstream CustomResourceDefinitions installed into the disposable kind cluster
by `scripts/fixtures/capture-drift.sh` so tern-kube can read Argo CD and Flux
objects. Only the CRDs are installed: no controller runs, so the sample
objects in `tests/integration/manifests/gitops/` never reconcile and their
status is patched in by the capture script.

The Argo CD CRD exceeds the client-side apply annotation limit; install with
`kubectl apply --server-side`.

| File | Source | sha256 |
| --- | --- | --- |
| argocd-application-crd.yaml | https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.4/manifests/crds/application-crd.yaml | 5dde0e229249b6b707beb98674c1deae3949d5c319a6c45b9f5a80c99618e40c |
| flux-kustomization-crd.yaml | https://raw.githubusercontent.com/fluxcd/kustomize-controller/v1.9.6/config/crd/bases/kustomize.toolkit.fluxcd.io_kustomizations.yaml | da23ca0e6b4c80d3d26a91583137491e147ef4ef1e2208aece0d0af4ef851974 |
| flux-helmrelease-crd.yaml | https://raw.githubusercontent.com/fluxcd/helm-controller/v1.6.5/config/crd/bases/helm.toolkit.fluxcd.io_helmreleases.yaml | aa8638ac68465ceac1f93a617baf5be833c589c51fd78a7384a4a274c252becc |
| flux-gitrepository-crd.yaml | https://raw.githubusercontent.com/fluxcd/source-controller/v1.9.6/config/crd/bases/source.toolkit.fluxcd.io_gitrepositories.yaml | bd0c08183287b2eea0d885751fc686bc4b2b583e919de6bd57859170b8d1727f |

Verify: `cd tests/integration/manifests/gitops-crds && shasum -a 256 *.yaml`.
The capture script refuses to install files whose digest differs.

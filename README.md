# Personal k8s Cluster using Flux V2
Kubernetes clusters using the GitOps tool [Flux](https://fluxcd.io/).
This git repository defines the configurations and apps that make up Kubernetes clusters. [Flux SOPS integration](https://toolkit.fluxcd.io/guides/mozilla-sops/) is used to encrypt secrets with gpg.

## Repository structure
The Git repository contains the following directories:
```sh
📁
├─📁 apps            # kustomization and overlays for app installations per cluster
│  ├─📁 base         # apps available for installation
│  ├─📁 staging
│  └─📁 prod
├─📁 charts          # helm chart repos
├─📁 clusters        # flux & gitops operator per cluster
│  ├─📁 staging
│  └─📁 prod
├─📁 configs         # configs per cluster
└─📁 infrastructure
   ├─📁 backup       # backup configurations (not operational)
   ├─📁 crds         # cluster crds
   └─📁 ingress      # traefik ingress definitions

```

## Software

The following apps are installed on the clusters.

| Software                                                                          | Purpose                                                       |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| [Flux2](https://fluxcd.io)                                                        | GitOps Tool managing the cluster                              |
| [Weave GitOps](https://www.weave.works/product/gitops/)                           | Powerful WebUI extension to Flux for deployment insights      |
| [Traefik Ingress Controller](https://doc.traefik.io/traefik/         )            | Cluster Ingress controller                                    |
| [Kube-Prometheus Stack](https://github.com/prometheus-operator/kube-prometheus)   | Prometheus & Exporters to monitor the cluster                 |
| [Grafana](https://grafana.com)                                                    | Monitoring & Logging Dashboard                                |
| [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager)           | Monitoring Alerts                                             |
| [Grafana Loki](https://grafana.com/oss/loki)                                      | Log aggregation system                                        |
| [Authelia](https://www.authelia.com)                                              | SSO & 2FA authentication server for Cluster Web Apps          |
| [Kutt](https://kutt.it/)                                                          | URL Shortener                                                 |
| [Vaultwarden](https://github.com/guerzon/vaultwarden/)                            | Password Manager                                              |
| [Plausible](https://plausible.io/)                                                | Analytics                                                     |
| [Tandoor-Receipes](https://github.com/TandoorRecipes/recipes)                     | Receipe Manager and Meal Planner                              |
| [Heimdall](https://heimdall.site/)                                                | Static dashboard for the cluster applications                 |
| [Lemonhope](https://github.com/anaximand/lemonhope/)                              | A simple discord bot                                          |


## Automation & Service deployment

The [Renovate](https://www.whitesourcesoftware.com/free-developer-tools/renovate) Bot will automatically create prs to update services.
Certain services have auto merging enabled, allowing the upstream repo to push tags, which in turn will automatically deploy to cluster.

### Auto Deployment
To enable auto deployment on upstream repos, this build workflow can be used. It creates a calver tag for every push to the main/default branch. This will be picked up by renovating and auto-deploying (usually, this functionality is a little buggy).

<details>
    <summary>.github/workflows/build.yaml</summary>
    name: Build and Publish Docker Image
    on:
      push:
        branches: ["main"]

    env:
      REGISTRY: ghcr.io
      IMAGE_NAME: ${{ github.repository }}

    jobs:
      build-and-push-image:
        runs-on: ubuntu-latest

        permissions:
          contents: write
          packages: write

        steps:
          - name: Checkout repository
            uses: actions/checkout@v4
            with:
              submodules: "true"
          - name: Log in to the Container registry
            uses: docker/login-action@v3.0.0
            with:
              registry: ${{ env.REGISTRY }}
              username: ${{ github.actor }}
              password: ${{ secrets.GITHUB_TOKEN }}

          - name: Get next version
            uses: reecetech/version-increment@2023.9.3
            id: version
            with:
              scheme: calver
              increment: patch

          - name: Extract metadata to create tags and labels
            id: meta
            uses: docker/metadata-action@v5.5.1
            with:
              images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
              tags: |
                type=raw,value=${{steps.version.outputs.version}},priority=300
                type=raw,value=latest,enable={{is_default_branch}}

          - name: Build and push Docker image
            uses: docker/build-push-action@v5.1.0
            with:
              context: .
              push: true
              tags: ${{ steps.meta.outputs.tags }}
              labels: ${{ steps.meta.outputs.labels }}

          - name: Create tag
            uses: actions/github-script@v5
            with:
              script: |
                github.rest.git.createRef({
                  owner: context.repo.owner,
                  repo: context.repo.repo,
                  ref: 'refs/tags/${{ steps.version.outputs.version }}',
                  sha: context.sha
                })
</details>


## Todo
* Custom charts / update some third party charts
* Statping/Healthchecks
* Plausible Analytics
* Headscale VPN

## Bootstrapping
1. Install k3s on the server with
```bash
k3sup install --ip ${SSH_IP_ADDRESS} --local-path ${KUBE_CONFIG} --ssh-key "~/.ssh/${SSH_KEY}" --k3s-extra-args '--disable traefik'
```

2. Add the `flux-system` namespace with
```bash
kubectl create namespace flux-system
```

3. Add the decryption key k3s with
```bash
gpg --export-secret-keys --armor ${GPG_FINGERPRINT} | kubectl create secret generic sops-gpg --namespace=flux-system --from-file=sops.asc=/dev/stdin
```

4. Bootstrap the cluster with
```bash
flux bootstrap github \
    --owner=serubin \
    --repository=flux-infra \
    --branch=main \
    --personal \
    --path=clusters/<cluster>
```

## Environments
### Staging Cluster
The staging cluster is a single-node Kubernetes instance (k3s) running on a Dell R410 on Debian.

### Production Cluster
The production cluster is a 6c/12t 32GB RAM server running on a dedibox cloud.

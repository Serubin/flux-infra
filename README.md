# Home Cluster
This is a work-in-progress configuration for my home cluster. It services two environments: an at-home test environment and a remote production environment.

Previously, this service cluster was run using docker swarm and and a homebrewed CI/CD pipeline. This project aims to move that cluster to Kubernetes and reproducible configurations.

At the moment, this only contains basic configurations for the staging cluster. I'm actively migrating all the apps on the legacy cluster to my staging system. Once this is done, I will set up the production cluster and migrate everything to that environment.

## Environments
### Staging Cluster
The staging cluster is a single-node Kubernetes instance (k3s) running on a Dell R410 on Debian.

### Production Cluster
The production cluster is a 6c/12t 32GB RAM server running on a dedibox cloud.

## Apps
* Gitlab
* Password manager
* Personal Website
* Websites for other people
* URL Shortener
* Personal File Cloud
* Statping/Healthchecks
* Plausible Analytics
* Obsidian Sync Service
* Recipe Manager
* Headscale VPN
* Home Assistant

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
    --path=clusters/staging
```

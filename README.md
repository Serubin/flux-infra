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

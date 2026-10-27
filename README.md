# WindyFlo for Google Cloud Marketplace

Packaging for deploying **WindyFlo** (a no-code AI workflow platform) on Google Kubernetes Engine through
Google Cloud Marketplace. This repository holds the Helm chart, the Marketplace deployer, and the
supporting container images. It does not contain the WindyFlo application source.

- Product: <https://windyflo.com>
- User guide: <https://windyflo.com/user-guide/how-to-build-pipelines>
- Privacy policy: <https://windyflo.com/privacy-policy>
- License terms: [deploy/marketplace/gcp/EULA.md](deploy/marketplace/gcp/EULA.md)

## What gets installed

All resources are created in one namespace, with no cluster-scoped operators or CRDs of our own:

| Component | Kind | Notes |
|---|---|---|
| `windyflo` main (API/UI), worker, collab | Deployments | autoscaled between 2 and the configured maximum |
| PostgreSQL | StatefulSet, 1 replica | 50 Gi PD-SSD volume |
| MinIO (S3 storage) | StatefulSet, 1 replica | 100 Gi PD-SSD volume |
| Redis | StatefulSet, 1 replica | 8 Gi volume, password-protected |
| Ingress, Services, NetworkPolicies, PodDisruptionBudgets | | |
| `Application` | `app.k8s.io/v1beta1` | owns every resource above, so uninstall removes everything |

Requirements: a GKE cluster (x86 nodes), an ingress controller of class `nginx`, and the `premium-rwo`
storage class (default on GKE).

## Deploy from the Cloud Console

Open the WindyFlo listing in Google Cloud Marketplace, choose **Configure**, then set:

| Parameter | Meaning |
|---|---|
| `name` | Application instance name |
| `namespace` | Namespace to install into |
| `ingress.host` | DNS name you will point at the cluster's load balancer |
| `main.autoscaling.maxReplicas`, `worker.autoscaling.maxReplicas` | Autoscaling ceilings (2 to 16) |

## Deploy from the command line

Install with Google's `mpdev` tool, which runs the same deployer image the console uses:

```bash
# Tools: https://github.com/GoogleCloudPlatform/marketplace-k8s-app-tools
kubectl create namespace windyflo
kubectl apply -f "https://raw.githubusercontent.com/GoogleCloudPlatform/marketplace-k8s-app-tools/master/crd/app-crd.yaml"

mpdev install \
  --deployer=us-docker.pkg.dev/windyflo-public/windyflo-marketplace/deployer:3.1 \
  --parameters='{"name":"windyflo","namespace":"windyflo","ingress.host":"windyflo.example.com"}'
```

Check the result:

```bash
kubectl -n windyflo get pods
kubectl -n windyflo get applications.app.k8s.io
kubectl -n windyflo get ingress
```

Point a DNS A record for your `ingress.host` at the ingress address, then open `http://<ingress.host>`.
TLS is not configured by default; terminate it at your load balancer or add cert-manager yourself.

Uninstall by deleting the Application, which removes everything it owns:

```bash
kubectl -n windyflo delete applications.app.k8s.io windyflo
```

## Repository layout

| Path | Contents |
|---|---|
| `deploy/charts/windyflo/` | The Helm chart; `values-marketplace-gcp.yaml` is the profile used by this listing |
| `deploy/marketplace/gcp/schema.yaml` | Deployer schema: the form fields and the container images declared to Marketplace |
| `deploy/marketplace/gcp/deployer/` | Dockerfile for the deployer image |
| `deploy/marketplace/gcp/images/` | Dockerfiles for the PostgreSQL, Redis and MinIO images |
| `deploy/marketplace/gcp/build-deployer.sh` | Builds and pushes the deployer image |
| `deploy/marketplace/gcp/push-image.sh` | Builds and pushes the supporting images |
| `deploy/marketplace/gcp/tools/dropempty/` | Helper that removes empty layers from images before publishing |

## Container images

Published in Artifact Registry under `us-docker.pkg.dev/windyflo-public/windyflo-marketplace`:
`deployer`, `windyflo/windyflo`, `windyflo/postgresql`, `windyflo/minio`, `windyflo/redis`,
tagged `3.1.3` and `3.1`.

## Support

Contact: <https://www.hamadalabs.com/contact>

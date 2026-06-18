# Frappe Helm Based Deployment

This repository contains a Docker and Helm based deployment setup for a Frappe application.  
It builds a custom Frappe image, installs required custom apps, pushes the final image to Harbor, and deploys the application to Kubernetes using a packaged Helm chart.

## Overview

The deployment flow is:

```text
Dockerfile.base
    ↓
Build base Frappe image with Python, Node.js, PostgreSQL client, wkhtmltopdf, bench, and site initialization
    ↓
Push base image to Harbor
    ↓
Dockerfile
    ↓
Use base image as builder, install custom Frappe apps, run migrate/build
    ↓
Create final runtime image
    ↓
GitLab CI builds and pushes image to Harbor
    ↓
GitLab CI deploys Helm chart to Kubernetes
```

## Repository Structure

```text
.
├── ci/
│   ├── nginx-template.conf
│   └── nginx-entrypoint.sh
├── helm/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── httproute.yaml
│       ├── service.yaml
│       └── site-config-secret.yaml
├── Dockerfile
├── Dockerfile.base
├── README.md
└── gitlab-ci.yaml

## Components

### 1. `Dockerfile.base`

`Dockerfile.base` is used to create the base Frappe image.

It includes:

- Python `3.11.6-slim-bookworm`
- Frappe user creation
- PostgreSQL 16 client
- Node.js `20.19.0` using NVM
- Yarn
- wkhtmltopdf
- Frappe Bench
- Required Python packages
- Required Linux packages
- Initial `bench init`
- Initial Frappe site creation using PostgreSQL

This base image is built once and pushed to Harbor. The final application image uses this base image.

### 2. `Dockerfile`

`Dockerfile` builds the final deployable Frappe image.

It performs the following:

- Uses the Harbor base image as the builder image
- Sets Redis queue/cache/socketio configuration
- Selects the Frappe site using `bench use`
- Pulls custom apps from GitLab
- Installs custom apps
- Runs database migration
- Clears cache
- Builds frontend assets for production
- Removes unnecessary `node_modules`
- Creates a smaller final runtime image
- Runs Frappe using Gunicorn

Installed apps:

```text
frappe_extensions
commit
dfp_external_storage
survey_v2
```

### 3. Helm Chart

The Helm chart deploys the Frappe application to Kubernetes.

Chart files include:

```text
Chart.yaml
values.yaml
templates/deployment.yaml
templates/service.yaml
templates/httproute.yaml
templates/site-config-secret.yaml
```

The chart is packaged and pushed to Harbor as an OCI Helm chart.

Example packaged chart files:

```text
frappe-0.2.0.tgz
frappe-0.3.0.tgz
frappe-0.5.0.tgz
frappe-0.6.0.tgz
```

## Base Image Build

Build the base image using `Dockerfile.base`.

> Do not hardcode real passwords or tokens in the command. Use temporary values, environment variables, or CI/CD variables.

Example:

```bash
docker build \
  --no-cache \
  --progress=plain \
  -f Dockerfile.base \
  -t gis-preprod:local \
  --build-arg FRAPPE_BRANCH=main \
  --build-arg FRAPPE_PATH="https://<GITLAB_USER>:<GITLAB_TOKEN>@gitlab.example.com/group/frappe-core.git" \
  --build-arg SITE_NAME=gis-survey-preprod-admin.example.com \
  --build-arg DB_TYPE=postgres \
  --build-arg DB_HOST=<DB_HOST> \
  --build-arg DB_PORT=5432 \
  --build-arg DB_NAME=<DB_NAME> \
  --build-arg DB_USER=<DB_USER> \
  --build-arg DB_PASSWORD=<DB_PASSWORD> \
  --build-arg DB_ROOT_PASSWORD=<DB_ROOT_PASSWORD> \
  --build-arg ADMIN_PASSWORD=<ADMIN_PASSWORD> \
  --build-arg REDIS_QUEUE=redis://<REDIS_HOST>:6384 \
  --build-arg REDIS_CACHE=redis://<REDIS_HOST>:6385 \
  --build-arg REDIS_SOCKETIO=redis://<REDIS_HOST>:6386 \
  .
```

Tag and push the base image to Harbor:

```bash
docker tag gis-preprod:local harbor.example.com/project/gis-preprod:base
docker push harbor.example.com/project/gis-preprod:base
```

For production usage, it is recommended to pin the base image using digest:

```dockerfile
FROM harbor.example.com/project/gis-preprod@sha256:<IMAGE_DIGEST> AS builder
```

## Application Image Build

The final application image is built from `Dockerfile`.

The final image:

- Copies the complete bench from the builder stage
- Installs runtime packages
- Configures Nginx
- Runs Gunicorn on port `8000`

Default command:

```bash
env PYTHONPATH=/home/frappe/frappe-bench/apps \
/home/frappe/frappe-bench/env/bin/gunicorn \
  --chdir=/home/frappe/frappe-bench/sites \
  --bind=0.0.0.0:8000 \
  --threads=4 \
  --workers=5 \
  --worker-class=gthread \
  --worker-tmp-dir=/dev/shm \
  --timeout=120 \
  --preload \
  frappe.app:application
```

## GitLab CI/CD Pipeline

The GitLab pipeline has two main stages:

```text
build
deploy
```

### Build Stage

The build stage uses Kaniko to build and push the Docker image to Harbor.

Image used:

```text
gcr.io/kaniko-project/executor:debug
```

The build stage:

1. Creates Harbor Docker authentication for Kaniko.
2. Generates a cache-bust value.
3. Builds the image using `Dockerfile`.
4. Passes required build arguments.
5. Pushes the image to Harbor using the Git commit SHA as tag.

Example destination:

```text
harbor.example.com/project/survey:<CI_COMMIT_SHA>
```

### Deploy Stage

The deploy stage uses Helm to deploy the packaged chart to Kubernetes.

Image used:

```text
alpine/helm:3.14.0
```

The deploy stage:

1. Installs `kubectl`.
2. Decodes the Kubernetes config from GitLab CI/CD variable.
3. Logs in to Harbor Helm registry.
4. Validates required variables.
5. Runs `helm upgrade --install`.
6. Waits for the deployment rollout.

Example Helm deployment command:

```bash
helm upgrade --install survey ${HELM_CHART} \
  --version ${HELM_CHART_VERSION} \
  --namespace gis-survey \
  --values values.yaml \
  --set image.tag="${CI_COMMIT_SHA}" \
  --set-string siteConfig.values.gis_user="${GIS_USER}" \
  --set-string siteConfig.values.gis_password="${GIS_PASSWORD}" \
  --set-string siteConfig.values.gis_end_url="${GIS_BASE_URL}" \
  --set-string siteConfig.values.superset_url="${SUPERSET_URL}" \
  --set-string siteConfig.values.superset_username="${SUPERSET_USERNAME}" \
  --set-string siteConfig.values.superset_password="${SUPERSET_PASSWORD}" \
  --wait \
  --timeout 10m
```

Rollout check:

```bash
kubectl rollout status deployment/gis-survey-all-in-one -n gis-survey
```

## Required GitLab CI/CD Variables

Configure the following variables in GitLab:

### Harbor Variables

```text
HARBOR_REGISTRY
HARBOR_USER
HARBOR_PASSWORD
```

### Kubernetes Variable

```text
KUBECONFIG_B64
```

`KUBECONFIG_B64` should contain the base64 encoded kubeconfig.

Create it using:

```bash
base64 -w 0 ~/.kube/config
```

### Helm Variables

```text
HELM_CHART
HELM_CHART_VERSION
```

Example:

```text
HELM_CHART=oci://harbor.example.com/helm/frappe
HELM_CHART_VERSION=0.6.0
```

### Application Variables

```text
GIS_USER
GIS_PASSWORD
GIS_BASE_URL
SUPERSET_URL
SUPERSET_USERNAME
SUPERSET_PASSWORD
```

These values are passed into the Helm chart and stored in the Kubernetes site config secret.

## Helm Chart Packaging

Package the Helm chart:

```bash
helm package .
```

Login to Harbor Helm registry:

```bash
helm registry login harbor.example.com
```

Push the chart:

```bash
helm push frappe-0.6.0.tgz oci://harbor.example.com/helm
```

Update GitLab variable:

```text
HELM_CHART_VERSION=0.6.0
```

## Manual Deployment

To deploy manually:

```bash
helm upgrade --install survey oci://harbor.example.com/helm/frappe \
  --version 0.6.0 \
  --namespace gis-survey \
  --create-namespace \
  --values values.yaml \
  --set image.tag=<IMAGE_TAG> \
  --wait \
  --timeout 10m
```

Check pods:

```bash
kubectl get pods -n gis-survey
```

Check services:

```bash
kubectl get svc -n gis-survey
```

Check HTTPRoute:

```bash
kubectl get httproute -n gis-survey
```

Check deployment rollout:

```bash
kubectl rollout status deployment/gis-survey-all-in-one -n gis-survey
```

## Useful Kubernetes Commands

View pods:

```bash
kubectl get pods -n gis-survey
```

View logs:

```bash
kubectl logs -f deployment/gis-survey-all-in-one -n gis-survey
```

Open shell inside pod:

```bash
kubectl exec -it deployment/gis-survey-all-in-one -n gis-survey -- bash
```

Run bench commands:

```bash
kubectl exec -it deployment/gis-survey-all-in-one -n gis-survey -- bash
cd /home/frappe/frappe-bench
bench --site gis-survey-preprod-admin.example.com migrate
bench --site gis-survey-preprod-admin.example.com clear-cache
```

Restart deployment:

```bash
kubectl rollout restart deployment/gis-survey-all-in-one -n gis-survey
```

## Rollback

Check rollout history:

```bash
kubectl rollout history deployment/gis-survey-all-in-one -n gis-survey
```

Rollback to previous revision:

```bash
kubectl rollout undo deployment/gis-survey-all-in-one -n gis-survey
```

Rollback Helm release:

```bash
helm rollback survey -n gis-survey
```

List Helm revisions:

```bash
helm history survey -n gis-survey
```

## Troubleshooting

### 1. GitLab variable missing

Error example:

```text
GIS_USER is missing
```

Fix:

- Go to GitLab project
- Open **Settings → CI/CD → Variables**
- Add the missing variable
- Make sure the variable is available for the target branch/environment

### 2. Image pull error

Check image and secret:

```bash
kubectl describe pod <pod-name> -n gis-survey
kubectl get secret -n gis-survey
```

Verify Harbor image exists:

```bash
docker pull harbor.example.com/project/survey:<IMAGE_TAG>
```

### 3. Helm chart version not found

Check chart versions in Harbor or pull manually:

```bash
helm pull oci://harbor.example.com/helm/frappe --version <VERSION>
```

### 4. Frappe migration issue

Open pod shell:

```bash
kubectl exec -it deployment/gis-survey-all-in-one -n gis-survey -- bash
cd /home/frappe/frappe-bench
bench --site <SITE_NAME> migrate
```

### 5. Redis config issue

Check Frappe global config:

```bash
cat /home/frappe/frappe-bench/sites/common_site_config.json
```

Expected keys:

```json
{
  "redis_queue": "redis://<REDIS_HOST>:6384",
  "redis_cache": "redis://<REDIS_HOST>:6385",
  "redis_socketio": "redis://<REDIS_HOST>:6386"
}
```

### 6. Nginx config issue

Check generated Nginx config:

```bash
cat /etc/nginx/conf.d/frappe.conf
```

Check Nginx logs:

```bash
kubectl logs -f deployment/gis-survey-all-in-one -n gis-survey
```

## Security Notes

Do not commit or hardcode:

- GitLab access tokens
- GitHub access tokens
- Harbor passwords
- Database passwords
- Admin passwords
- Superset passwords
- Kubernetes kubeconfig files

Use GitLab CI/CD variables or Kubernetes secrets instead.

If any token or password was committed or pasted in logs, rotate it immediately.

Recommended improvements:

- Use GitLab CI/CD masked and protected variables
- Use deploy tokens instead of personal access tokens where possible
- Use Kubernetes secrets for runtime credentials
- Avoid passing secrets as Docker build arguments
- Avoid embedding Git credentials in Dockerfile `RUN bench get-app` commands
- Use SSH deploy keys or CI job tokens for private Git repositories
- Pin base images using immutable digests
- Keep Helm chart versions immutable
- Use separate values files per environment

## Current Deployment Target

Example environment:

```text
Namespace: gis-survey
Release name: survey
Deployment: gis-survey-all-in-one
Application image: harbor.example.com/project/survey:<CI_COMMIT_SHA>
Helm chart: oci://harbor.example.com/helm/frappe
```

## Notes

- The base image contains the initialized bench and site.
- The final image contains the installed custom apps and production build.
- The Helm chart controls Kubernetes deployment, service, HTTPRoute, and site config secret.
- The GitLab pipeline deploys only from the `staging` branch as configured.

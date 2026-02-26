# EP2-ventures Infra Workflows

Public reusable GitHub Actions workflows for building and deploying Docker images to a VPS. Can be called from any organization (e.g. EP2-ventures, playbackzone-org).

## Workflows

### build-reusable.yml

Builds a Docker image and pushes to GHCR. Fetches Dockerfiles and configs from `EP2-ventures/infra` (private) via `INFRA_TOKEN`.

**Inputs**

| Input | Required | Description |
|-------|----------|-------------|
| `service` | yes | `backend` or `frontend` |
| `project` | yes | Project name (e.g. `boanalytics`, `pbz`) |
| `image_name` | yes | GHCR image name (e.g. `ep2-ventures/boanalytics-backend`) |
| `build_context` | yes | Docker build context path relative to project repo root |
| `build_args` | no | Docker build args, one per line `KEY=VALUE` |

**Secrets**

| Secret | Description |
|--------|-------------|
| `INFRA_TOKEN` | PAT with read access to `EP2-ventures/infra` |

**Outputs**

- `image_tag` — Tag applied to the built image
- `image_url` — Full image URL including registry

### deploy-reusable.yml

SSH deploys a pre-built image to the VPS at `/opt/{project}/`.

**Inputs**

| Input | Required | Description |
|-------|----------|-------------|
| `service` | yes | `backend` or `frontend` |
| `project` | yes | Project name (must match VPS path) |
| `image_name` | yes | GHCR image name |
| `image_tag` | yes | Tag to deploy |

**Secrets**

| Secret | Description |
|--------|-------------|
| `DEPLOY_HOST` | VPS hostname or IP |
| `DEPLOY_USER` | SSH user |
| `DEPLOY_SSH_KEY` | Private SSH key for VPS access |
| `GHCR_TOKEN` | Token to pull images from GHCR on the VPS |

## Usage

```yaml
# Build
uses: EP2-ventures/infra-workflows/.github/workflows/build-reusable.yml@main
with:
  service: backend
  project: boanalytics
  image_name: ep2-ventures/boanalytics-backend
  build_context: backend
secrets:
  INFRA_TOKEN: ${{ secrets.INFRA_TOKEN }}

# Deploy
uses: EP2-ventures/infra-workflows/.github/workflows/deploy-reusable.yml@main
with:
  service: backend
  project: boanalytics
  image_name: ep2-ventures/boanalytics-backend
  image_tag: ${{ needs.build.outputs.image_tag }}
secrets:
  DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
  DEPLOY_USER: ${{ secrets.DEPLOY_USER }}
  DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
  GHCR_TOKEN: ${{ secrets.GHCR_TOKEN }}
```

## Tag convention

- `staging` branch → `staging-{run}-{sha}`
- `main` branch → `release-{run}-{sha}`
- Other branches → `snapshot-{branch}-{run}-{sha}`

## Handoff

When handing off a project to another org, the client can fork this repo and update their pipeline to use their fork:

```yaml
uses: their-org/infra-workflows/.github/workflows/build-reusable.yml@main
```

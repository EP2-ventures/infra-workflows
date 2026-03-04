# EP2-ventures Infra Workflows

Public reusable GitHub Actions workflows for building and deploying Docker images to a VPS. Can be called from any organization (e.g. EP2-ventures, playbackzone-org).

## Workflows

### build-reusable.yml

Builds a Docker image and pushes to GHCR. Fetches Dockerfiles and configs from the infra repo via `INFRA_TOKEN`.

**Inputs**

| Input | Required | Description |
|-------|----------|-------------|
| `service` | yes | `backend` or `frontend` |
| `project` | yes | Project name (e.g. `boanalytics`, `pbz`) |
| `image_name` | yes | GHCR image name (e.g. `ep2-ventures/boanalytics-backend`) |
| `build_context` | yes | Docker build context path relative to project repo root |
| `build_args` | no | Docker build args, one per line `KEY=VALUE` |
| `infra_repo` | yes | Infra repo `owner/repo` (e.g. `EP2-ventures/infra`, `playback-zone/pbz-infra`) |
| `infra_ref` | no | Branch or ref to checkout from infra repo (default: `main`) |

**Secrets**

| Secret | Description |
|--------|-------------|
| `INFRA_TOKEN` | PAT with read access to the infra repo |

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
| `infra_repo` | yes | Infra repo `owner/repo` — docker-compose is always copied before deploy |
| `infra_ref` | no | Branch or ref to checkout from infra repo (default: `main`) |
| `environment` | no | GitHub environment name for deployment tracking (defaults to `project` name) |
| `environment_url` | no | URL shown in GitHub deployment status (e.g. `https://api.boanalytics.ep2.ventures`) |

**Secrets**

| Secret | Description |
|--------|-------------|
| `INFRA_TOKEN` | PAT to checkout infra repo (when `infra_repo` is set) |
| `DEPLOY_HOST` | VPS hostname or IP |
| `DEPLOY_USER` | SSH user |
| `DEPLOY_SSH_KEY` | Private SSH key for VPS access |
| `DOPPLER_TOKEN` | (optional) Doppler service token — when provided, `.env` is regenerated from Doppler before deploy |

## Usage

```yaml
# Build
uses: EP2-ventures/infra-workflows/.github/workflows/build-reusable.yml@v1
with:
  service: backend
  project: boanalytics
  image_name: ep2-ventures/boanalytics-backend
  build_context: backend
  infra_repo: EP2-ventures/infra
secrets:
  INFRA_TOKEN: ${{ secrets.INFRA_TOKEN }}

# Deploy
uses: EP2-ventures/infra-workflows/.github/workflows/deploy-reusable.yml@v1
with:
  service: backend
  project: boanalytics
  image_name: ep2-ventures/boanalytics-backend
  image_tag: ${{ needs.build.outputs.image_tag }}
  infra_repo: EP2-ventures/infra
secrets:
  INFRA_TOKEN: ${{ secrets.INFRA_TOKEN }}
  DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
  DEPLOY_USER: ${{ secrets.DEPLOY_USER }}
  DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
  DOPPLER_TOKEN: ${{ secrets.DOPPLER_TOKEN }}
```

## Infra / VPS contract

The workflows expect a consistent layout in both the infra repo and on the VPS.

### Infra repo layout

```
projects/
  {project}/
    backend/
      Dockerfile.prod
      .dockerignore
      docker-entrypoint.prod.sh   # optional
    frontend/
      Dockerfile.prod
      .dockerignore
      nginx.conf                  # optional
    docker-compose.prod.yml
```

- `{project}` must match the `project` input (e.g. `boanalytics`, `pbz`).
- Each service (`backend`, `frontend`) needs a `Dockerfile.prod` and `.dockerignore`.
- `docker-compose.prod.yml` defines services named `backend` and/or `frontend` and is copied to the VPS on every deploy.

### VPS layout

```
/opt/{project}/
  docker-compose.prod.yml   # overwritten on each deploy
  .env                      # managed manually; contains secrets and config
```

- `{project}` must match the infra path and the `project` input.
- `.env` is regenerated from Doppler on each deploy when `DOPPLER_TOKEN` is provided. `IMAGE_TAG` is appended automatically.
- Without `DOPPLER_TOKEN`, the existing `.env` is preserved and only `IMAGE_TAG` is updated.
- The deploy step runs `docker compose -f docker-compose.prod.yml pull` and `up -d` in `/opt/{project}/`.

## Concurrency

Deploy jobs use a concurrency group `deploy-{project}` with `cancel-in-progress: false`. This means:
- Only one deploy runs per project at a time.
- Queued deploys wait (they are NOT cancelled).
- This prevents containerd commit failures from concurrent `docker compose` operations.

## Tag convention

- `staging` branch → `staging-{run}-{sha}`
- `main` branch → `release-{run}-{sha}`
- Other branches → `snapshot-{branch}-{run}-{sha}`

## Handoff

When handing off a project to another org, the client can fork this repo and update their pipeline to use their fork:

```yaml
uses: their-org/infra-workflows/.github/workflows/build-reusable.yml@v1
```

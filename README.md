# GitHub issues → Microsoft Teams bot

Posts an Adaptive Card to a Teams channel when a GitHub issue is opened, updated (edited), closed or reopened.

```
GitHub issues webhook ──► Azure Container Apps (FastAPI + Teams SDK for Python) ──► Teams channel (Adaptive Card)
```

- **Auth, no secrets:** a single user-assigned managed identity is the Azure Bot identity (`UserAssignedMSI`), pulls from ACR, reads Key Vault and writes Blob Storage.
- **Key Vault** holds the GitHub webhook secret; the Container App reads it through the managed identity.
- **Blob Storage** (identity-only access) persists the Teams conversation(s) that receive notifications.
- Key Vault and Storage have public access disabled; the Container Apps environment is VNet-integrated and reaches them via private endpoints.
- The card shows title, description, status/labels/assignees and an **Open issue on GitHub** button.

## Layout

| Path | Purpose |
|------|---------|
| `bot/` | Python app (`src/main.py` webhook + Teams handlers, `src/cards.py`, `src/store.py`) |
| `infra/` | Bicep for azd (resource group, identity, ACR, Key Vault, Storage, Container App, Azure Bot + Teams channel) |
| `appPackage/`, `scripts/build-app-package.sh` | Teams app manifest template and packaging |

## Deploy

```bash
azd env new teams-bot-demo
azd env set AZURE_LOCATION centralus
azd env set GITHUB_WEBHOOK_SECRET "$(openssl rand -hex 32)"
azd env set AZURE_PRINCIPAL_ID "$(az ad signed-in-user show --query id -o tsv)"
azd provision          # creates infra with a placeholder image
azd deploy             # builds the bot in ACR and rolls it out
scripts/build-app-package.sh
```

1. Sideload `appPackage/build/teams-app.zip` in Teams and add the app to the target team/channel.
2. Add the GitHub webhook (`azd env get-value GITHUB_WEBHOOK_URL`): content type `application/json`, the same secret, events **Issues** and **Issue comments**.

## Run locally

```bash
cd bot && python -m venv .venv && . .venv/bin/activate && pip install -e .
GITHUB_WEBHOOK_SECRET=dev python src/main.py
```

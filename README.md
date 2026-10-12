# GitHub issues → Microsoft Teams bot

Posts an Adaptive Card to a Teams channel when a GitHub issue is opened, edited, closed or reopened, or when someone comments on it.

```
GitHub ──webhook──► Container App (your code) ──► Azure Bot Service ──► Teams channel
```

## How the pieces fit

| Component | Role |
|-----------|------|
| **GitHub webhook** | Calls our URL whenever an issue or comment event happens. Signed with a shared secret so we can reject fakes. |
| **Azure Container Apps** | Runs our Python app in a container. It receives the webhook, decides if the event matters, builds the card and sends it. Also receives Teams' own calls at `/api/messages`. |
| **Teams SDK (Python)** | The library inside the app that talks to Teams: it validates Teams' requests, handles "bot was added to a channel", and sends messages. |
| **Azure Bot Service** | The bot's registration in Azure. It gives the bot its identity and connects it to the Teams channel, forwarding Teams messages to our app and our replies back to Teams. It doesn't run any of our code. |
| **Teams app package** | The zip you upload to Teams. It tells Teams the bot exists, its name, icon and where it can be added (team channels). |
| **Managed identity** | One Azure-issued identity used by the bot and by the app to reach ACR, Key Vault and Storage. No passwords or keys to store. |
| **Key Vault** | Holds the GitHub webhook secret. The app reads it at startup through the managed identity. |
| **Blob Storage** | Remembers which channels to notify, so the list survives restarts. |
| **Container Registry (ACR)** | Stores the app's container image. |
| **VNet + private endpoints** | Keep Key Vault and Storage off the public internet; the Container App reaches them privately. |

**Flow:** adding the bot to a channel makes Teams call the app, which saves that channel. Later, a GitHub event hits the webhook; the app checks the signature, filters the event, builds the card and sends it to each saved channel through the Teams SDK and Bot Service.

## Layout

| Path | Purpose |
|------|---------|
| `bot/` | Python app (`src/main.py` webhook + Teams handlers, `src/cards.py`, `src/store.py`) |
| `infra/` | Bicep for azd (resource group, identity, ACR, Key Vault, Storage, Container App, Azure Bot + Teams channel) |
| `appPackage/`, `scripts/build-app-package.sh` | Teams app manifest template and packaging |

## Deploy

```bash
azd env new teams-bot-demo
azd env set AZURE_LOCATION eastus2
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

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

## Appendix: Estimated monthly cost

Estimate for the deployed configuration in **East US 2**: one Container App (0.5 vCPU, 1 GiB, always on with 1 replica) and a low event volume (a few hundred GitHub events a month). Prices are pay-as-you-go list prices in USD from the [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices), checked on 2026-10-12. A month is 730 hours (2,628,000 seconds). Taxes, discounts and agreements are not included. Prices change, so confirm with the [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/).

| Service | How it's billed | Calculation | Est. / month |
|---------|-----------------|-------------|-------------:|
| **Container Apps** (Consumption) | Per-second vCPU and memory. A replica that is up but not handling requests is billed at the lower *idle* rate. First 180,000 vCPU-s and 360,000 GiB-s per subscription are free. | vCPU: (0.5 × 2,628,000 − 180,000) s × $0.000003 = $3.40<br>Memory: (1 × 2,628,000 − 360,000) GiB-s × $0.000003 = $6.80<br>Active time (a few seconds per event) ≈ $0.01 | **≈ $10.20** |
| Container Apps requests | $0.40 per million; first 2 million free | A few hundred requests | **$0.00** |
| **Azure Bot Service** (F0 tier) | Free tier. Teams is a standard channel, which is not metered. | n/a | **$0.00** |
| **Private endpoints** (Key Vault, Blob Storage) | $0.01 per endpoint-hour, plus $0.01 per GB of data processed | 2 × 730 h × $0.01 = $14.60; data is a few KB | **$14.60** |
| **Azure Container Registry** (Basic) | $0.1666 per day, includes 10 GiB storage | 30.4 days × $0.1666; one small image, far below 10 GiB | **≈ $5.07** |
| **Private DNS zones** (2) | $0.50 per zone per month; $0.40 per million queries | 2 × $0.50; negligible queries | **$1.00** |
| **Key Vault** (Standard) | $0.03 per 10,000 operations | The secret is read only when the app starts | **< $0.01** |
| **Blob Storage** (Hot LRS) | $0.0184 per GB-month, plus per-operation fees | One small JSON file | **< $0.01** |
| **Log Analytics** | Ingestion at $2.76 per GB after the free monthly allowance (5 GB per billing account); 31-day retention included | Container logs, well under 1 GB | **$0.00** |
| Managed identity, VNet, Container Apps environment | No charge | The environment has only a Consumption profile, so no Dedicated plan management fee applies | **$0.00** |
| | | **Total** | **≈ $31** |

If the free grants are already used up by other apps in the subscription, Container Apps costs about $11.80 instead of $10.20 and the total is about **$32.50**.

**Where the money goes:** the two private endpoints are about 47% of the bill and the always-on replica about 33%.

**Check your real bill:** Cost Management in the Azure portal, filtered to resource group `rg-teams-bot-eus2`, shows actual charges. It's the best way to confirm assumptions like the free grant and no Dedicated plan fee.

### References

- [Pricing - Azure AI Bot Service | Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/bot-services/)
- [Pricing - Azure Container Apps | Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/container-apps/)
- [Billing in Azure Container Apps | Microsoft Learn](https://learn.microsoft.com/en-us/azure/container-apps/billing)
- [Compute and billing structures in Azure Container Apps | Microsoft Learn](https://learn.microsoft.com/en-us/azure/container-apps/plans)
- [Set scaling rules in Azure Container Apps | Microsoft Learn](https://learn.microsoft.com/en-us/azure/container-apps/scale-app)
- [Pricing - Container Registry | Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/container-registry/)
- [Pricing - Key Vault | Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/key-vault/)
- [Pricing - Blob Storage | Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/storage/blobs/)
- [Pricing - Azure Private Link | Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/private-link/)
- [Pricing - Azure DNS | Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/dns/)
- [Pricing - Virtual Network | Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/virtual-network/)
- [Pricing - Azure Monitor | Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/monitor/)
- [Azure Monitor Logs cost calculations and options | Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cost-logs)
- [Azure Retail Prices API | Microsoft Learn](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Azure pricing calculator | Microsoft Azure](https://azure.microsoft.com/en-us/pricing/calculator/)

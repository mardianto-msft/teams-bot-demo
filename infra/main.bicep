targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment, used to name resources.')
param environmentName string

@minLength(1)
@description('Azure region for all resources.')
param location string

@secure()
@description('Shared secret configured on the GitHub webhook. Stored in Key Vault.')
param githubWebhookSecret string

@description('Object ID of the deploying principal; granted rights to manage Key Vault secrets. Optional.')
param deployerPrincipalId string = ''

@description('Container image; the public quickstart image is used until `azd deploy` publishes the bot.')
param botImageName string = ''

var abbrs = { rg: 'rg-', id: 'id-', acr: 'cr', kv: 'kv-', st: 'st', log: 'log-', cae: 'cae-', ca: 'ca-', bot: 'bot-' }
var token = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: '${abbrs.rg}${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    tags: tags
    token: token
    abbrs: abbrs
    githubWebhookSecret: githubWebhookSecret
    deployerPrincipalId: deployerPrincipalId
    botImageName: botImageName
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.registryEndpoint
output AZURE_KEY_VAULT_NAME string = resources.outputs.keyVaultName
output BOT_ID string = resources.outputs.identityClientId
output BOT_ENDPOINT string = resources.outputs.messagingEndpoint
output GITHUB_WEBHOOK_URL string = resources.outputs.webhookUrl

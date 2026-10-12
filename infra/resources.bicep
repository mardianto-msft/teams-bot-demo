param location string
param tags object
param token string
param abbrs object
@secure()
param githubWebhookSecret string
param deployerPrincipalId string
param botImageName string

var quickstartImage = 'mcr.microsoft.com/k8se/quickstart:latest'

// Built-in role definition IDs
var acrPullRole = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var keyVaultSecretsUserRole = '4633458b-17de-408a-b874-0445c86b69e6'
var keyVaultSecretsOfficerRole = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var storageBlobDataContributorRole = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

// One identity for the Container App and for the Azure Bot registration (type UserAssignedMSI).
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${abbrs.id}${token}'
  location: location
  tags: tags
}

resource logs 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${abbrs.log}${token}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: '${abbrs.acr}${token}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${abbrs.kv}${token}'
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${abbrs.st}${token}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

// Key Vault and Storage are private-only (subscription policy disables public access), so the
// Container Apps environment is VNet-integrated and reaches them through private endpoints.
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${abbrs.vnet}${token}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'aca'
        properties: {
          addressPrefix: '10.0.0.0/23'
          delegations: [
            { name: 'aca', properties: { serviceName: 'Microsoft.App/environments' } }
          ]
        }
      }
      {
        name: 'private-endpoints'
        properties: { addressPrefix: '10.0.2.0/24' }
      }
    ]
  }
}

var privateEndpoints = [
  { name: 'kv', resourceId: keyVault.id, groupId: 'vault', zone: 'privatelink.vaultcore.azure.net' }
  { name: 'blob', resourceId: storage.id, groupId: 'blob', zone: 'privatelink.blob.${environment().suffixes.storage}' }
]

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for pe in privateEndpoints: {
  name: pe.zone
  location: 'global'
  tags: tags
}]

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (pe, i) in privateEndpoints: {
  parent: zones[i]
  name: 'link-${pe.name}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

resource endpoints 'Microsoft.Network/privateEndpoints@2023-09-01' = [for pe in privateEndpoints: {
  name: 'pe-${pe.name}-${token}'
  location: location
  tags: tags
  properties: {
    subnet: { id: vnet.properties.subnets[1].id }
    privateLinkServiceConnections: [
      {
        name: pe.name
        properties: { privateLinkServiceId: pe.resourceId, groupIds: [pe.groupId] }
      }
    ]
  }
}]

resource endpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = [for (pe, i) in privateEndpoints: {
  parent: endpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: pe.name, properties: { privateDnsZoneId: zones[i].id } }
    ]
  }
}]

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storage
  name: 'default'
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'state'
}

resource webhookSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'github-webhook-secret'
  properties: { value: githubWebhookSecret }
}

// RBAC for the managed identity. These only depend on the identity and the target resources,
// never on the Container App, so the app can pull its image and read secrets on first provision.
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, identity.id, acrPullRole)
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRole)
  }
}

resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, identity.id, keyVaultSecretsUserRole)
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRole)
  }
}

resource blobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, identity.id, storageBlobDataContributorRole)
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRole)
  }
}

resource deployerKvOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: keyVault
  name: guid(keyVault.id, deployerPrincipalId, keyVaultSecretsOfficerRole)
  properties: {
    principalId: deployerPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficerRole)
  }
}

resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${abbrs.cae}${token}'
  location: location
  tags: tags
  properties: {
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
    vnetConfiguration: {
      infrastructureSubnetId: vnet.properties.subnets[0].id
      internal: false
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${abbrs.ca}${token}'
  location: location
  tags: union(tags, { 'azd-service-name': 'bot' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: registry.properties.loginServer
          identity: identity.id
        }
      ]
      secrets: [
        {
          name: 'github-webhook-secret'
          keyVaultUrl: webhookSecret.properties.secretUri
          identity: identity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'bot'
          image: empty(botImageName) ? quickstartImage : botImageName
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'PORT', value: '80' }
            // CLIENT_ID without CLIENT_SECRET makes the Teams SDK authenticate with the user-assigned managed identity.
            { name: 'CLIENT_ID', value: identity.properties.clientId }
            { name: 'TENANT_ID', value: tenant().tenantId }
            { name: 'MANAGED_IDENTITY_CLIENT_ID', value: identity.properties.clientId }
            { name: 'STORAGE_ACCOUNT_URL', value: storage.properties.primaryEndpoints.blob }
            { name: 'STORAGE_CONTAINER', value: stateContainer.name }
            { name: 'GITHUB_WEBHOOK_SECRET', secretRef: 'github-webhook-secret' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 2 }
    }
  }
  dependsOn: [acrPull, kvSecretsUser, endpointDns]
}

var messagingEndpoint = 'https://${app.properties.configuration.ingress.fqdn}/api/messages'

resource bot 'Microsoft.BotService/botServices@2022-09-15' = {
  name: '${abbrs.bot}${token}'
  location: 'global'
  tags: tags
  sku: { name: 'F0' }
  kind: 'azurebot'
  properties: {
    displayName: 'GitHub Ticket Bot'
    endpoint: messagingEndpoint
    msaAppId: identity.properties.clientId
    msaAppMSIResourceId: identity.id
    msaAppTenantId: tenant().tenantId
    msaAppType: 'UserAssignedMSI'
  }
}

resource teamsChannel 'Microsoft.BotService/botServices/channels@2022-09-15' = {
  parent: bot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
    properties: { isEnabled: true }
  }
}

output registryEndpoint string = registry.properties.loginServer
output keyVaultName string = keyVault.name
output identityClientId string = identity.properties.clientId
output messagingEndpoint string = messagingEndpoint
output webhookUrl string = 'https://${app.properties.configuration.ingress.fqdn}/api/github/webhook'

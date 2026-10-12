Design notes:
- Create Teams bot that receives notification when a GitHub issue is created, updated, close (i.e., status change)
- Use Teams SDK Python language
- Use teams-dev skill
- Use Azure Container Apps as the backend service
- Use Azure Key Vault, if needed, to store GitHub API key
- Use user-assigned managed identity to access between Azure resources, so no secrets are needed
- The workflow: GitHub issue webhook -> Business Logic hosted in Azure Container Apps (using Teams SDK) -> send Adaptive Cards to MS Teams
- Use Teams' Adaptive Card that shows the important information, including: title, description, and a button that opens the GitHub issue in a browser
- Use AZD CLI deployment (Bicep) to deploy the Azure resources
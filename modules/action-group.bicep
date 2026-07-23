@description('Name of the action group resource.')
param actionGroupName string

@description('Short name for the action group (max 12 chars, shown in notifications).')
@maxLength(12)
param shortName string

@description('Email address that receives a notification when an alert fires.')
param emailAddress string

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'Global'
  properties: {
    groupShortName: shortName
    enabled: true
    emailReceivers: [
      {
        name: 'alertEmail'
        emailAddress: emailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

@description('Resource ID of the action group.')
output actionGroupId string = actionGroup.id

@description('Azure region for all resources.')
param location string

@description('Name of the dedicated virtual network.')
param vnetName string

@description('Address space for the virtual network.')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('Address prefix for the AKS node subnet.')
param aksSubnetPrefix string = '10.10.0.0/22'

var aksSubnetName = 'aks'

// Default NSG for the AKS subnet. Ships with no custom rules, so only Azure's default
// security rules apply (intra-VNet + outbound allowed, inbound from internet denied).
resource aksNsg 'Microsoft.Network/networkSecurityGroups@2024-10-01' = {
  name: '${vnetName}-aks-nsg'
  location: location
  properties: {}
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-10-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: aksSubnetName
        properties: {
          addressPrefix: aksSubnetPrefix
          // Disable the (retiring) implicit default outbound access. AKS provides explicit
          // egress via its standard load balancer, so nodes don't rely on default outbound.
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: aksNsg.id
          }
        }
      }
    ]
  }
}

output aksSubnetId string = '${vnet.id}/subnets/${aksSubnetName}'

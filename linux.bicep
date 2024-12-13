param pLocation string
param pVmName string
param pAdminUsername string
@secure()
param pAdminPassword string
@secure()
param pSshPublicKey string

// Network Resource Declaration
var vAddressPrefix = '10.1.0.0/16'
var vSubnetAddressPrefix = '10.1.1.0/24'
resource rVirtualNetwork 'Microsoft.Network/virtualNetworks@2023-06-01' = {
  name: 'vnet-${pVmName}'
  location: pLocation
  properties: {
    addressSpace: {
      addressPrefixes: [
        vAddressPrefix
      ]
    }
  }
}

resource rSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-06-01' = {
  name: 'subnet-${pVmName}'
  parent: rVirtualNetwork
  properties: {
    addressPrefix: vSubnetAddressPrefix
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

resource rPublicIp 'Microsoft.Network/publicIPAddresses@2023-06-01' = {
  name: 'pip-${pVmName}'
  location: pLocation
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: {
      domainNameLabel: toLower(pVmName)
    }
    idleTimeoutInMinutes: 4
  }
}

resource rNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-06-01' = {
  name: 'nsg-${pVmName}'
  location: pLocation
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'Allow-HTTPS'
        properties: {
          protocol: 'TCP'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        name: 'Allow-HTTP'
        properties: {
          protocol: 'TCP'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 120
          direction: 'Inbound'
        }
      }
    ]
  }
}

resource vNetworkInterface 'Microsoft.Network/networkInterfaces@2023-06-01' = {
  name: 'nic-${pVmName}'
  location: pLocation
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig-${pVmName}'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: rSubnet.id
          }
          publicIPAddress: {
            id: rPublicIp.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: rNetworkSecurityGroup.id
    }
  }
}

// Image reference
// var vImageReference = {
//   publisher: 'Canonical'
//   offer: '0001-com-ubuntu-server-jammy'
//   sku: '22_04-lts-gen2'
//   version: 'latest'
// }

var vImageReference = {
  publisher: 'Canonical'
  offer: 'ubuntu-24_04-lts'
  sku: 'server'
  version: 'latest'
}

// Vm settings
resource rVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: pVmName
  location: pLocation
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2ats_v2'
    }
    storageProfile: {
      imageReference: vImageReference
      osDisk: {
        name: 'osdisk_${pVmName}'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
        diskSizeGB: 30
      }
    }
    osProfile: union(empty(pAdminPassword) ? {} : {
      adminPassword: pAdminPassword
    }, union(empty(pSshPublicKey) ? {} : {
      linuxConfiguration: {
        disablePasswordAuthentication: empty(pAdminPassword) ? true : false
        ssh: {
          publicKeys: empty(pSshPublicKey) ? [] : [
            {
              path: '/home/${pAdminUsername}/.ssh/authorized_keys'
              keyData: pSshPublicKey
            }
          ]
        }
      }
    }, {
      computerName: pVmName
      adminUsername: pAdminUsername
    }))
    networkProfile: {
      networkInterfaces: [
        {
          id: vNetworkInterface.id
        }
      ]
    }
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
      securityType: 'TrustedLaunch'
    }
  }
}

// resource rGuestAttestationExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
//   parent: rVm
//   name: 'GuestAttestation'
//   location: pLocation
//   properties: {
//     publisher: 'Microsoft.Azure.Security.LinuxAttestation'
//     type: 'GuestAttestation'
//     typeHandlerVersion: '1.0'
//     autoUpgradeMinorVersion: true
//     enableAutomaticUpgrade: true
//     settings: {
//       MaaSettings: {
//         attestationType: 'ISe'
//       }
//     }
//   }
// }

// resource rSetupExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
//   parent: rVm
//   name: 'InstallScript'
//   location: pLocation
//   properties: {
//     publisher: 'Microsoft.Azure.Extensions'
//     type: 'CustomScript'
//     typeHandlerVersion: '2.1'
//     autoUpgradeMinorVersion: true
//     settings: {
//       fileUris: [
//         'https://raw.githubusercontent.com/Azure/azure-linux-extensions/master/VMAccess/1.5.6/handle-extensions.sh'
//       ]
//       protectedSettings: {
//         commandToExecute: 'bash handle-extensions.sh'
//       }
//     }
//   }
// }

output adminUsername string = pAdminUsername
output ipAddress string = rPublicIp.properties.ipAddress
output hostname string = rPublicIp.properties.dnsSettings.fqdn

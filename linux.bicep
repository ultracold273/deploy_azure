param pLocation string
param pVmName string
param pAdminUsername string
@secure()
param pAdminPassword string
@secure()
param pSshPublicKey string
param pCustomPort int?

// Network Resource Declaration
var vAddressV4Prefix = '10.1.0.0/16'
var vAddressV6Prefix = 'fd00:10:0::/48'
var vSubnetAddressV4Prefix = '10.1.1.0/24'
var vSubnetAddressV6Prefix = 'fd00:10:0:1::/64'
resource rVirtualNetwork 'Microsoft.Network/virtualNetworks@2023-06-01' = {
  name: 'vnet-${pVmName}'
  location: pLocation
  properties: {
    addressSpace: {
      addressPrefixes: [
        vAddressV4Prefix
        vAddressV6Prefix
      ]
    }
  }
}

resource rSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-06-01' = {
  name: 'subnet-${pVmName}'
  parent: rVirtualNetwork
  properties: {
    addressPrefixes: [
      vSubnetAddressV4Prefix
      vSubnetAddressV6Prefix
    ]
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

resource rPublicIpv4 'Microsoft.Network/publicIPAddresses@2023-06-01' = {
  name: 'pip4-${pVmName}'
  location: pLocation
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: {
      domainNameLabel: '${toLower(pVmName)}-v4'
    }
    idleTimeoutInMinutes: 4
  }
}

resource rPublicIpv6 'Microsoft.Network/publicIPAddresses@2023-06-01' = {
  name: 'pip6-${pVmName}'
  location: pLocation
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv6'
    dnsSettings: {
      domainNameLabel: '${toLower(pVmName)}-v6'
    }
    idleTimeoutInMinutes: 4
  }
}

resource rNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-06-01' = {
  name: 'nsg-${pVmName}'
  location: pLocation
  properties: {
    securityRules: union([
      {
        name: 'Allow-SSH'
        properties: {
          protocol: 'TCP'
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
      {
        name: 'Allow-QUIC'
        properties: {
          protocol: 'UDP'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 130
          direction: 'Inbound'
        }
      }
    ], (pCustomPort == null) ? [] : [
      {
        name: 'Allow-CustomPort'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: string(pCustomPort)
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 140
          direction: 'Inbound'
        }
      }
    ])
  }
}

resource vNetworkInterface 'Microsoft.Network/networkInterfaces@2023-06-01' = {
  name: 'nic-${pVmName}'
  location: pLocation
  properties: {
    ipConfigurations: [
      {
        name: 'ipv4-${pVmName}'
        properties: {
          primary: true
          privateIPAddressVersion: 'IPv4'
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: rSubnet.id
          }
          publicIPAddress: {
            id: rPublicIpv4.id
          }
        }
      }
      {
        name: 'ipv6-${pVmName}'
        properties: {
          primary: false
          privateIPAddressVersion: 'IPv6'
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: rSubnet.id
          }
          publicIPAddress: {
            id: rPublicIpv6.id
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
output ipAddress string = rPublicIpv4.properties.ipAddress
output hostname string = rPublicIpv4.properties.dnsSettings.fqdn
output ipAddressV6 string = rPublicIpv6.properties.ipAddress
output hostnameV6 string = rPublicIpv6.properties.dnsSettings.fqdn

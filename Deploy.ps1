$TOML_FILE = "config.toml"

function ConvertFrom-Toml {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
        [string]$line
    )

    begin {
        $result = @{}
        $regex = '([\w\-]+)\s*=\s*(".*"|\d+|true|false|)'
    }

    process {
        $line = $line.Trim()

        # Skip empty or comment line
        if ($line -eq '' -or $line -match '^\s*#') {
            continue
        }

        if ($line -match $regex) {
            $key = $matches[1]
            $value = $matches[2]

            if ($value -match '^".*"$') {
                $value = $value.Trim('"')
            }
            elseif ($value -match '^\d+$') {
                $value = [int]$value
            }
            elseif ($value -match '^true$|^false$') {
                $value = [bool]$value
            }

            $result[$key] = $value
        }
    }

    end {
        $result
    }
}

$configs = Get-Content $TOML_FILE | ConvertFrom-Toml

$validKeys = @("DIRECTORY_ID", "SUBSCRIPTION_ID", "RESOURCE_GROUP_NAME", "LOCATION", "VM_NAME", "ADMIN_USERNAME", "ADMIN_PASSWORD")

$validKeys | ForEach-Object {
    if (-not $configs.ContainsKey($_)) {
        Write-Host "Missing key $_ in $TOML_FILE"
        exit 1
    }
}

Write-Host "Get the configuration from $TOML_FILE"

$DirectoryId = $configs["DIRECTORY_ID"]
$SubscriptionId = $configs["SUBSCRIPTION_ID"]
$ResourceGroupName = $configs["RESOURCE_GROUP_NAME"]
$Location = $configs["LOCATION"]
$VmName = $configs["VM_NAME"]
$AdminUsername = $configs["ADMIN_USERNAME"]
$AdminPassword = $configs["ADMIN_PASSWORD"]
$TemplateFilePath = "linux.bicep"

Write-Host "DirectoryId: $DirectoryId"
Write-Host "SubscriptionId: $SubscriptionId"
Write-Host "ResourceGroupName: $ResourceGroupName"
Write-Host "Location: $Location"
Write-Host "VM Name: $VmName"
Write-Host "Admin Username: $AdminUsername"
Write-Host "Admin Password: $AdminPassword"

function Confirm-VmName {
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    if ($VmName.Length -lt 1 -or $VmName.Length -gt 64) {
        Write-Host "The VM name must be 1-64 characters long."
        exit 1
    }

    if ($VmName -cnotmatch "^[a-zA-Z0-9]([-a-zA-Z0-9]{0,62})[a-zA-Z0-9]$") {
        Write-Host "The VM name must contain only letters and digits or hypen and cannot start or end with hypens"
        exit 1
    }

    Write-Host "VM name $VmName is valid."
}

function Confirm-Password {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Passkey
    )

    if ($Passkey.Length -lt 6 -or $Passkey.Length -gt 72) {
        Write-Host "The password must be at least 12 characters and at most 72 characters long."
        exit 1
    }

    $score = 0
    if ($Passkey -match "[A-Z]") { $score++ }
    if ($Passkey -match "[a-z]") { $score++ }
    if ($Passkey -match "[0-9]") { $score++ }
    if ($Passkey -match "[^a-zA-Z0-9]") { $score++ }

    if ($score -lt 3) {
        Write-Host "The password must contain at least three of the following: uppercase letter, lowercase letter, number, and special character."
        exit 1
    }

    Write-Host "Password $Passkey is valid."
}

Confirm-VmName -VmName $VmName

Confirm-Password -Passkey $AdminPassword

az login --tenant $DirectoryId # --use-device-code
az account set --subscription $SubscriptionId

$resourceGroup = az group show --name $ResourceGroupName --query "name" --output json 2>$null
if (-not $resourceGroup) {
    Write-Host "Resource Group $ResourceGroupName does not exist. Creating it ..."
    az group create --name $ResourceGroupName --location $Location --output none
}

$deploymentOutput = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $TemplateFilePath `
    --parameters `
        pLocation=$Location `
        pVmName=$VmName `
        pAdminUsername=$AdminUsername `
        pAdminPassword=$AdminPassword `
        pSshPublicKey= `
    --output json | Tee-Object -Variable deploymentOutput

$deploymentOutput = $deploymentOutput | ConvertFrom-Json

$DeploymentResult = $deploymentOutput.properties.provisioningState

if ($DeploymentResult -ne "Succeeded") {
    Write-Host "Deployment failed."
    exit 1
}

Write-Host "Deployment Result: $DeploymentResult"

$IpAddress = $deploymentOutput.properties.outputs.ipAddress.value
$Hostname = $deploymentOutput.properties.outputs.hostname.value

if ($null -eq $IpAddress -or $null -eq $Hostname) {
    Write-Host "Failed to get the IP address or hostname. Exit.."
    exit 1
}

Write-Host "IP Address: $IpAddress"
Write-Host "Hostname: $Hostname"

$trojanAddress = "https://raw.githubusercontent.com/ultracold273/deploy_azure/refs/heads/main/trojan.sh"

$commandOutput = az vm run-command invoke `
    --resource-group $ResourceGroupName `
    --name $VmName `
    --command-id RunShellScript `
    --scripts "curl -s $trojanAddress | bash -s -- $Hostname $IpAddress" | Tee-Object -Variable commandOutput

$commandOutput = $commandOutput | ConvertFrom-Json
$Message = $commandOutput.value[0].message

if ($Message -match "Now you can setup your client with passcode: (\w+) or (\w+)") {
    $passcode1 = $matches[1]
    $passcode2 = $matches[2]
    Write-Host "Passcode 1: $passcode1"
    Write-Host "Passcode 2: $passcode2"
} else {
    Write-Host "Failed to get the passcode. Exit.."
    exit 1
}

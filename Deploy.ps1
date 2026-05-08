$TOML_FILE = "config.toml"
$TargetFqdnMax = 64

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
$optionalKeys = @("NTFY_TOPIC", "DNS_LABEL")

$validKeys | ForEach-Object {
    if (-not $configs.ContainsKey($_)) {
        Write-Host "Missing key $_ in $TOML_FILE"
        exit 1
    }
}

# Handle optional keys with defaults
$optionalKeys | ForEach-Object {
    if (-not $configs.ContainsKey($_)) {
        $configs[$_] = ""
        Write-Host "Optional key $_ not found, using default"
    } else {
        Write-Host "Check $_ -- DONE (optional)"
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
$NtfyTopic = $configs["NTFY_TOPIC"]
$DnsLabel = $configs["DNS_LABEL"]
$TemplateFilePath = "linux.bicep"
$Port = Get-Random -Minimum 1024 -Maximum 65537

Write-Host "DirectoryId: $DirectoryId"
Write-Host "SubscriptionId: $SubscriptionId"
Write-Host "ResourceGroupName: $ResourceGroupName"
Write-Host "Location: $Location"
Write-Host "VM Name: $VmName"
Write-Host "Admin Username: $AdminUsername"
Write-Host "Admin Password: $AdminPassword"
Write-Host "Port: $Port"

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

function Confirm-DnsLabel {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DnsLabel
    )

    if ($DnsLabel.Length -lt 3 -or $DnsLabel.Length -gt 60) {
        Write-Host "The DNS label must be 3-60 characters long."
        exit 1
    }

    if ($DnsLabel -cnotmatch "^[a-z]([-a-z0-9]{1,58})[a-z0-9]$") {
        Write-Host "The DNS label must contain only lowercase letters, digits or hyphens, start with a letter, and end with a letter or digit."
        exit 1
    }
}

function Normalize-DnsLabel {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InputLabel
    )

    $normalized = $InputLabel.ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, "[^a-z0-9-]", "-")
    $normalized = [regex]::Replace($normalized, "-+", "-").Trim('-')

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $normalized = "vm"
    }

    if ($normalized[0] -notmatch "[a-z]") {
        $normalized = "v-$normalized"
    }

    $normalized = [regex]::Replace($normalized, "-+", "-").Trim('-')

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $normalized = "vm"
    }

    return $normalized
}

function Get-Sha256Hex {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $sha.ComputeHash($bytes)
        return -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $sha.Dispose()
    }
}

function New-SafeDnsLabelBase {
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true)]
        [string]$Location,
        [string]$RequestedLabel = ""
    )

    $suffix = ".${Location}.cloudapp.azure.com"
    $reserved = 3 # reserve for -v4 / -v6 suffix
    $labelLimit = [Math]::Min(60, $TargetFqdnMax - $suffix.Length - $reserved)

    if ($labelLimit -lt 3) {
        Write-Host "Location suffix is too long to build a safe DNS label under target FQDN limit $TargetFqdnMax."
        exit 1
    }

    $source = if ([string]::IsNullOrWhiteSpace($RequestedLabel)) { $VmName } else { $RequestedLabel }
    $normalized = Normalize-DnsLabel -InputLabel $source
    $hash = (Get-Sha256Hex -Text $source).Substring(0, 8)
    $prefixLimit = $labelLimit - $hash.Length - 1

    if ($prefixLimit -lt 1) {
        Write-Host "Safe DNS label budget is too small."
        exit 1
    }

    $prefix = if ($normalized.Length -gt $prefixLimit) { $normalized.Substring(0, $prefixLimit) } else { $normalized }
    $prefix = $prefix.TrimEnd('-')
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = "v"
    }

    $candidate = "$prefix-$hash"
    $candidate = [regex]::Replace($candidate, "-+", "-").Trim('-')
    if ($candidate[0] -notmatch "[a-z]") {
        $candidate = "v-$candidate"
    }
    if ($candidate.Length -gt $labelLimit) {
        $candidate = $candidate.Substring(0, $labelLimit).TrimEnd('-')
    }

    Confirm-DnsLabel -DnsLabel $candidate
    return $candidate
}

function Confirm-Password {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Passkey
    )

    if ($Passkey.Length -lt 6 -or $Passkey.Length -gt 72) {
        Write-Host "The password must be at least 6 characters and at most 72 characters long."
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

$DnsLabelBase = New-SafeDnsLabelBase -VmName $VmName -Location $Location -RequestedLabel $DnsLabel
$HostnamePreview = "$DnsLabelBase-v4.$Location.cloudapp.azure.com"
$HostnameV6Preview = "$DnsLabelBase-v6.$Location.cloudapp.azure.com"

Write-Host "DNS Label Base: $DnsLabelBase"
Write-Host "Hostname v4: $HostnamePreview"
Write-Host "Hostname v6: $HostnameV6Preview"
Write-Host "Final FQDN lengths: v4=$($HostnamePreview.Length), v6=$($HostnameV6Preview.Length)"

Confirm-Password -Passkey $AdminPassword

# Disable the subscription selector
az config set core.login_experience_v2=off

# Login and set the subscription
az login --tenant $DirectoryId # --use-device-code
az account set --subscription $SubscriptionId

$resourceGroup = az group show --name $ResourceGroupName --query "name" --output json 2>$null
if (-not $resourceGroup) {
    Write-Host "Resource Group $ResourceGroupName does not exist. Creating it ..."
    az group create --name $ResourceGroupName --location $Location --output none
}

Write-Host "Start to deploy server..."

$deploymentOutput = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $TemplateFilePath `
    --parameters `
        pLocation=$Location `
        pVmName=$VmName `
        pDnsLabelBase=$DnsLabelBase `
        pAdminUsername=$AdminUsername `
        pAdminPassword=$AdminPassword `
        pCustomPort=$Port `
        pSshPublicKey= `
    --output json | Tee-Object -Variable deploymentOutput

$deploymentOutput = $deploymentOutput | ConvertFrom-Json

$DeploymentResult = $deploymentOutput.properties.provisioningState

Write-Host "Deployment Result: $DeploymentResult"

if ($DeploymentResult -ne "Succeeded") {
    exit 1
}

$IpAddress = $deploymentOutput.properties.outputs.ipAddress.value
$Hostname = $deploymentOutput.properties.outputs.hostname.value
$HostnameV6 = $deploymentOutput.properties.outputs.hostnameV6.value

if ($null -eq $IpAddress -or $null -eq $Hostname) {
    Write-Host "Failed to get the IP address or hostname. Exit.."
    exit 1
}

Write-Host "Start to configure server..."

$setupAddress = "https://raw.githubusercontent.com/ultracold273/deploy_azure/main/setup.sh"

$commandOutput = az vm run-command invoke `
    --resource-group $ResourceGroupName `
    --name $VmName `
    --command-id RunShellScript `
    --scripts "curl -s $setupAddress | bash -s -- $Hostname $HostnameV6 $IpAddress $Port $NtfyTopic" | Tee-Object -Variable commandOutput

$commandOutput = $commandOutput | ConvertFrom-Json
$Message = $commandOutput.value[0].message

Write-Host "IP Address: $IpAddress"
Write-Host "Hostname: $Hostname"

if ($Message -match "\n\[Summary\]: (.*)\n\n") {
    Write-Host $matches[1]
} else {
    Write-Host "Command Output: $Message"
    exit 1
}

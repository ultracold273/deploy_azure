
function DeployTemplateAzCli {
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$DirectoryId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [Parameter(Mandatory = $true)]
        [string]$TemplateFilePath,

        [Parameter(Mandatory = $true)]
        [object]$TemplateParameter
    )

    az login --tenant $DirectoryId
    az account set --subscription $SubscriptionId

    # test if the resource group exists
    $resourceGroup = az group show --name $ResourceGroupName --query "name" --output tsv 2>$null
    if (-not $resourceGroup) {
        Write-Host "Resource Group $ResourceGroupName does not exist. Creating it ..."
        az group create --name $ResourceGroupName --location $Location --output none
    }

    # deploy the template
    $parameterList = $TemplateParameter.GetEnumerator() | ForEach-Object {
        if ($null -ne $_.Value) {
            "$($_.Key)=`"$($_.Value)`""
        } else {
            "$($_.Key)=`"`""
        }
    }

    $deploymentOutput = $(az deployment group create `
        --resource-group $ResourceGroupName `
        --template-file $TemplateFilePath `
        --parameters $parameterList `
        --output json)

    return $deploymentOutput | ConvertFrom-Json
}

if ([string]::IsNullOrEmpty($adminPassword)) {
    Write-Host "Generating a new SSH key pair ..."
    ssh-keygen.exe -t rsa -b 2048 -m PEM -f $vmName -N ""

    # test if the public and private file exists
    if (-not (Test-Path -Path "$vmName")) {
        Write-Host "Private key file $vmName does not exist. Exiting ..."
        exit
    }
    if (-not (Test-Path -Path "$vmName.pub")) {
        Write-Host "Public key file $vmName.pub does not exist. Exiting ..."
        exit
    }

    # read the public key file
    $publicKey = Get-Content -Path "$vmName.pub"
}

if ([string]::IsNullOrEmpty($publicKey) -and [string]::IsNullOrEmpty($adminPassword)) {
    Write-Host "Public key and admin password are both empty. Exiting ..."
    exit
}

$parameter = @{
    pLocation      = $Location
    pVmName        = $vmName
    pAdminUsername = $adminUserName
    pAdminPassword = $adminPassword
    pSshPublicKey  = $publicKey
}

$deployment = DeployTemplateAzCli -DirectoryId $DirectoryId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -Location $Location -TemplateFilePath $TemplateFilePath -TemplateParameter $parameter

$ipAddress = $deployment.properties.outputs.ipAddress.value
$hostname = $deployment.properties.outputs.hostname.value

Write-Host "The VM $vmName has been created with IP address $ipAddress and hostname $hostname."
if ([string]::IsNullOrEmpty($adminPassword)) {
    Write-Host "you can now use `ssh -i $vmName $adminUserName@$hostname` to connect to the VM."
} else {
    Write-Host "you can now use `ssh $adminUserName@$hostname` to connect to the VM."
}

$trojanAddress="https://raw.githubusercontent.com/ultracold273/deploy_azure/refs/heads/main/trojan.sh"

$commandOutput = $(az vm run-command invoke `
    --resource-group $ResourceGroupName `
    --name $vmName `
    --command-id RunShellScript `
    --scripts "curl -s $trojanAddress | bash -s -- $hostname $ipAddress")

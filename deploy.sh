#!/bin/bash
TOML_FILE="config.toml"

declare -A config
while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | sed 's/ #.*//;s/[ "]*//g' | xargs)

    [ -z "$key" ] || [ -z "$value" ] && continue

    echo "$key = $value"
    config["$key"]="$value"
done < <(grep -E '^[^#]*=' "$TOML_FILE")

TARGET_KEYS=("DIRECTORY_ID" "SUBSCRIPTION_ID" "RESOURCE_GROUP_NAME" "LOCATION" "VM_NAME" "ADMIN_USERNAME" "ADMIN_PASSWORD")

for key in "${TARGET_KEYS[@]}"; do
    if [[ -v config[$key] ]]; then
        echo "Check $key -- DONE"
        declare "$key=${config[$key]}"
    else
        echo "Cannot find $key, exit..."
        exit 1
    fi
done

check_password() {
    local input="$1"
    
    local length=${#input}
    if [[ $length -lt 6 || $length -gt 72 ]]; then
        return 1
    fi

    local has_uppercase='[A-Z]'         # Upper Case
    local has_lowercase='[a-z]'         # Lower Case
    local has_digit='[0-9]'             # Digits
    local has_special='[^a-zA-Z0-9]'    # Special Characters
    
    local score=0
    [[ $input =~ $has_uppercase ]] && ((score++))
    [[ $input =~ $has_lowercase ]] && ((score++))
    [[ $input =~ $has_digit ]] && ((score++))
    [[ $input =~ $has_special ]] && ((score++))
    
    if [[ $score -ge 3 ]]; then
        return 0
    else
        return 2
    fi
}

validate_vm_name() {
    local name="$1"
    local length=${#name}

    if [[ $length -lt 1 || $length -gt 64 ]]; then
        echo "Name length shall be within 1 and 64."
        return 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9]{0,62})[a-zA-Z0-9]$ ]]; then
        echo "Name shall only contain letters, digits or hypen and cannot start or end with hypens."
        return 1
    fi

    return 0
}

validate_vm_name $VM_NAME
status=$?
if [[ $status -ne 0 ]]; then
    echo "Invalid VM name"
    exit 1
fi

check_password $ADMIN_PASSWORD
status=$?
if [[ $status -eq 1 ]]; then
    echo "Password length shall between 6 and 72"
    exit 1
elif [[ $status -eq 2 ]]; then
    echo -e "Password shall at least contains 3 of 4 complexities following: \r\n\
        1. Contains Upper Case letters \r\n\
        2. Contains Lower Case letters \r\n\
        3. Contains Digits \r\n\
        4. Contains Special Characters\r\n"
    exit 1
fi

az login --tenant $DIRECTORY_ID
az account set --subscription $SUBSCRIPTION_ID

# # test if the resource group exists
RESOURCE_GROUP=$(az group show --name $RESOURCE_GROUP_NAME --query "name" --output tsv 2>/dev/null)
if [ -z "$RESOURCE_GROUP" ]; then
    echo "Resource Group $RESOURCE_GROUP_NAME does not exist. Creating it ..."
    az group create --name $RESOURCE_GROUP_NAME --location $LOCATION --output none
fi

echo "Deploying..."
PARAMETERS="pLocation=$LOCATION pVmName=$VM_NAME pAdminUsername=$ADMIN_USERNAME pAdminPassword=$ADMIN_PASSWORD pSshPublicKey="
deploymentOutput=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --template-file "$TEMPLATE_FILE_PATH" \
    --parameters $PARAMETERS \
    --output json)

HOSTNAME=$(echo "$deploymentOutput" | jq '.properties.outputs.hostname.value' )
IPADDRESS=$(echo "$deploymentOutput" | jq '.properties.outputs.ipAddress.value' )

SETUP_ADDRESS="https://raw.githubusercontent.com/ultracold273/deploy_azure/main/setup.sh"

scriptOutput=$(az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "curl -s $SETUP_ADDRESS | bash -s -- $HOSTNAME $IPADDRESS"
    --output json)

echo $scriptOutput

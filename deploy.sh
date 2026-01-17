#!/bin/bash
TOML_FILE="config.toml"

TEMPLATE_FILE_PATH="linux.bicep"

declare -A config
while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | sed 's/ #.*//;s/[ "]*//g' | xargs)

    [ -z "$key" ] || [ -z "$value" ] && continue

    echo "$key = $value"
    config["$key"]="$value"
done < <(grep -E '^[^#]*=' "$TOML_FILE")

TARGET_KEYS=("DIRECTORY_ID" "SUBSCRIPTION_ID" "RESOURCE_GROUP_NAME" "LOCATION" "VM_NAME" "ADMIN_USERNAME" "ADMIN_PASSWORD")
OPTIONAL_KEYS=("NTFY_TOPIC")

for key in "${TARGET_KEYS[@]}"; do
    if [[ -v config[$key] ]]; then
        echo "Check $key -- DONE"
        declare "$key=${config[$key]}"
    else
        echo "Cannot find $key, exit..."
        exit 1
    fi
done

# Handle optional keys
for key in "${OPTIONAL_KEYS[@]}"; do
    if [[ -v config[$key] ]]; then
        echo "Check $key -- DONE (optional)"
        declare "$key=${config[$key]}"
    else
        echo "Optional key $key not found, using default"
        declare "$key="
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

# Generate a random number between 1024 and 65536
PORT=$(od -An -N2 -i /dev/urandom | awk '{print $1 % 64513 + 1024}')

echo Directory Id: $DIRECTORY_ID
echo Subscription Id: $SUBSCRIPTION_ID
echo Resource Group Name: $RESOURCE_GROUP_NAME
echo Location: $LOCATION
echo VM Name: $VM_NAME
echo Admin Username: $ADMIN_USERNAME
echo Admin Password: $ADMIN_PASSWORD
echo Port: $PORT

# Disable the subscription selector feature
az config set core.login_experience_v2=off

# Login and set the subscription
az login --tenant $DIRECTORY_ID
az account set --subscription $SUBSCRIPTION_ID

# test if the resource group exists
resourceGroup=$(az group show --name $RESOURCE_GROUP_NAME --query "name" --output tsv 2>/dev/null)
if [ -z "$resourceGroup" ]; then
    echo "Resource Group $RESOURCE_GROUP_NAME does not exist. Creating it ..."
    az group create --name $RESOURCE_GROUP_NAME --location $LOCATION --output none
fi

echo Start to deploy server...

PARAMETERS="pLocation=$LOCATION pVmName=$VM_NAME pAdminUsername=$ADMIN_USERNAME pAdminPassword=$ADMIN_PASSWORD pCustomPort=$PORT pSshPublicKey="
deploymentOutput=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --template-file "$TEMPLATE_FILE_PATH" \
    --parameters $PARAMETERS \
    --output json | tee /dev/tty)

DEPLOYRESULT=$(echo "$deploymentOutput" | jq -r '.properties.provisioningState')

echo Deployment Result: $DEPLOYRESULT

if ! [[ "$DEPLOYRESULT" == "Succeeded" ]]; then
    exit 1
fi

HOSTNAME=$(echo "$deploymentOutput" | jq -r '.properties.outputs.hostname.value' )
IPADDRESS=$(echo "$deploymentOutput" | jq -r '.properties.outputs.ipAddress.value' )
HOSTNAMEV6=$(echo "$deploymentOutput" | jq -r '.properties.outputs.hostnameV6.value' )

echo Start to configure server...

SETUP_ADDRESS="https://raw.githubusercontent.com/ultracold273/deploy_azure/main/setup.sh"

scriptOutput=$(az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "curl -s $SETUP_ADDRESS | bash -s -- $HOSTNAME $HOSTNAMEV6 $IPADDRESS $PORT $NTFY_TOPIC" \
    --output json | tee /dev/tty)

MESSAGE=$(echo "$scriptOutput" | jq -r '.value[0].message' )

SUMMARY=$(echo "$MESSAGE" | grep -oE '\[Summary\]: ([^[]*)' | sed -e 's/\[Summary\]:\s*//g')

echo IP Address: $IPADDRESS
echo Hostname: $HOSTNAME

if ! [[ -z $SUMMARY ]]; then
    echo $SUMMARY
else
    echo $MESSAGE
    exit 1
fi

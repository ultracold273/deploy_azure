#!/bin/bash
TOML_FILE="config.toml"

TEMPLATE_FILE_PATH="linux.bicep"
TARGET_FQDN_MAX=64

declare -A config
while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | sed 's/ #.*//;s/[ "]*//g' | xargs)

    [ -z "$key" ] || [ -z "$value" ] && continue

    echo "$key = $value"
    config["$key"]="$value"
done < <(grep -E '^[^#]*=' "$TOML_FILE")

TARGET_KEYS=("DIRECTORY_ID" "SUBSCRIPTION_ID" "RESOURCE_GROUP_NAME" "LOCATION" "VM_NAME" "ADMIN_USERNAME" "ADMIN_PASSWORD")
OPTIONAL_KEYS=("NTFY_TOPIC" "DNS_LABEL")

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

validate_dns_label() {
    local label="$1"
    local length=${#label}

    if [[ $length -lt 3 || $length -gt 60 ]]; then
        echo "DNS label length shall be within 3 and 60."
        return 1
    fi

    if [[ ! "$label" =~ ^[a-z]([-a-z0-9]{1,58})[a-z0-9]$ ]]; then
        echo "DNS label shall contain only lowercase letters, digits or hyphens, start with a letter and end with a letter or digit."
        return 1
    fi

    return 0
}

normalize_dns_label() {
    local input="$1"
    local normalized
    normalized=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')
    if [[ -z "$normalized" ]]; then
        normalized="vm"
    fi
    if [[ ! "$normalized" =~ ^[a-z] ]]; then
        normalized="v-$normalized"
    fi
    normalized=$(printf '%s' "$normalized" | sed -E 's/-{2,}/-/g; s/^-+//; s/-+$//')
    if [[ -z "$normalized" ]]; then
        normalized="vm"
    fi
    printf '%s' "$normalized"
}

build_dns_label_base() {
    local vm_name="$1"
    local location="$2"
    local requested_label="$3"
    local suffix=".${location}.cloudapp.azure.com"
    local reserved="3"
    local label_limit=$((TARGET_FQDN_MAX - ${#suffix} - reserved))

    if (( label_limit > 60 )); then
        label_limit=60
    fi
    if (( label_limit < 3 )); then
        echo "Location suffix is too long to build a safe DNS label under target FQDN limit ${TARGET_FQDN_MAX}."
        return 1
    fi

    local source="$requested_label"
    if [[ -z "$source" ]]; then
        source="$vm_name"
    fi

    local normalized
    normalized=$(normalize_dns_label "$source")

    local hash
    hash=$(printf '%s' "$source" | sha256sum | cut -c1-8)

    local sep="-"
    local hash_len=${#hash}
    local prefix_limit=$((label_limit - hash_len - ${#sep}))
    if (( prefix_limit < 1 )); then
        echo "Safe DNS label budget is too small."
        return 1
    fi

    local prefix=${normalized:0:prefix_limit}
    prefix=$(printf '%s' "$prefix" | sed -E 's/-+$//')
    if [[ -z "$prefix" ]]; then
        prefix="v"
    fi

    local candidate="$prefix-$hash"
    candidate=$(printf '%s' "$candidate" | sed -E 's/-{2,}/-/g; s/^-+//; s/-+$//')

    if [[ ! "$candidate" =~ ^[a-z] ]]; then
        candidate="v-$candidate"
    fi

    if (( ${#candidate} > label_limit )); then
        candidate=${candidate:0:label_limit}
        candidate=$(printf '%s' "$candidate" | sed -E 's/-+$//')
    fi

    if ! validate_dns_label "$candidate"; then
        return 1
    fi

    printf '%s' "$candidate"
}

validate_vm_name $VM_NAME
status=$?
if [[ $status -ne 0 ]]; then
    echo "Invalid VM name"
    exit 1
fi

DNS_LABEL_BASE=$(build_dns_label_base "$VM_NAME" "$LOCATION" "$DNS_LABEL")
status=$?
if [[ $status -ne 0 ]]; then
    echo "Failed to generate a safe DNS label"
    exit 1
fi

FQDN_V4="${DNS_LABEL_BASE}-v4.${LOCATION}.cloudapp.azure.com"
FQDN_V6="${DNS_LABEL_BASE}-v6.${LOCATION}.cloudapp.azure.com"

echo DNS Label Base: $DNS_LABEL_BASE
echo Hostname v4: $FQDN_V4
echo Hostname v6: $FQDN_V6

echo Final FQDN lengths: v4=${#FQDN_V4}, v6=${#FQDN_V6}

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

PARAMETERS="pLocation=$LOCATION pVmName=$VM_NAME pDnsLabelBase=$DNS_LABEL_BASE pAdminUsername=$ADMIN_USERNAME pAdminPassword=$ADMIN_PASSWORD pCustomPort=$PORT pSshPublicKey="
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

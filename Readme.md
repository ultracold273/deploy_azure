## Installation

Make sure your system has installed the [Azure Cli](https://learn.microsoft.com/en-us/cli/azure/). If not, please follow the guidelines in the link to install it. Also make sure the utility is correctly put in your system's PATH.

## Configuration
The configuration files looks like in the following format:
```toml
[Authentication]
DirectoryId = "your_directory_id"
SubscriptionId = "subscription_id"

[Deploy]
ResourceGroupName = "resource_group_name"
Location = "southeastasia"
TemplateFilePath = "linux.bicep"
vmName = "your_vm_name"
adminUserName = "azureuser"
adminPassword = "your_password"
``` 
Find your directory ID (i.e, tenant ID in some cases) and the subscription ID you own. Put them in the respective field.

In the `Deploy` table, you'll need to specify the resource group name you want to created on Azure and the location you want to put your vm. Noted that try to choose some unique name for your vm as it will also serve as the DNS for your VM.

# Execute
On windows, use powershell to execute:
```powershell
> .\DeployVM.ps1
```

On Mac, run the following commang in bash:
```bash
$ ./deployVM.sh
```

Login to the VM using the prompt of the output and download the trojan.sh to the VM. Run it with:
```bash
$ sudo ./trojan.sh
```
Then you are done.
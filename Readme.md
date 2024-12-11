## Installation

Make sure your system has installed the [Azure Cli](https://learn.microsoft.com/en-us/cli/azure/). If not, please follow the guidelines in the link to install it. Also make sure the utility is correctly put in your system's PATH.

## Configuration
Create a configuration file named `config.toml` and put the following configurations in it:
```
[resources]
DIRECTORY_ID = "your_directory_id"
SUBSCRIPTION_ID = "your_subscription_id"
[machine]
RESOURCE_GROUP_NAME = "your_resource_group"
LOCATION = "southeastasia"
VM_NAME = "your_vm_name"
ADMIN_USERNAME = "your_admin_username"
ADMIN_PASSWORD = "your_admin_password"
```
You can find a copy of sample config files in this repo by `config-sample.toml`.
Find your directory ID (i.e, tenant ID in some cases) and the subscription ID you own. Put them in the respective field.

You'll need to specify the resource group name you want to created on Azure and the location you want to put your vm. Noted that try to choose some unique name for your vm as it will also serve as the DNS for your VM.

# Execute
On windows, use powershell to execute:
```powershell
> .\Deploy.ps1
```

On Mac, run the following commang in bash:
```bash
$ ./deploy.sh
```

The script will automatically set up a Trojan server with random generated passcode. The passcode is printed in the shell's output. Please be careful to check the outputs. It shall be two passcode of 10 character length.

Setup your client to connect to the server.

Then you are done.

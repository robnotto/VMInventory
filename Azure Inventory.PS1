# -------------------------------------------------------------------------------------------------------------- 
# THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND,  
# EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED  
# WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE. 
# 
#  Title         : AzureARMVMDetailedInventorywithTags 
#  Programmed by : Denis Rougeau 
#  Date          : Oct, 2017 
#  Modified for Az PS CMDLets:  Robert Nottoli, 4/20
# 
# -------------------------------------------------------------------------------------------------------------- 
#  GET THE Original VERSION HERE: https://github.com/azureautomation/azure-arm-detailed-vm-inventory-with-tags/blob/master/AzureARMVMinventorywithTags.ps1
# -------------------------------------------------------------------------------------------------------------- 
# 
# Demo Script to create Azure VM List into a CSV files with VM Tags as header (One file per subscription) 
#
# NOTE: Support for multiple NIC, IP, Public IP, Data Disks per VMs
#       Multiple values within the same field are separated by " Carriage Return "
#       Added support for Managed Disks and Premium disks
#
# Headers:
# - Az_Location
# - Az_ResourceGroup
# - Az_Name
# - Az_Status                     -> Running/Stopped/Deallocated
# - Az_Statuscode                 -> OK/Failed... VM in Error status
# - Az_AvZone                     -> Availability Zone    *** NEW PREVIEW ***
# - Az_AvSet
# - Az_Size                       -> VM Size (ex. Standard_A1_V2)
# - Az_Cores                      -> # Cores
# - Az_Memory                     -> Memory size
# - Az_OSType                     -> Windows/Linux
# - Az_VNicNames                  -> Display all VNics name attached to the VM
# - Az_VNicProvisioningState      -> Succeeded/Failed.  NIC Provisionning Status
# - Az_VNicPrivateIPs
# - Az_vNicPrivateIPAllocMethods  -> Static/Dynamic
# - Az_VirtualNetworks
# - Az_Subnets
# - Az_VNicPublicIP
# - Az_VNicPublicIPAllocMethod    -> Static/Dynamic
# - Az_VM_Instance_SLA            -> If all VM disks are Premium and VM is a xS_ series, Azure offer 99.9 percent service-level agreement(SLA) (https://azure.microsoft.com/en-us/support/legal/sla/virtual-machines/)
# - Az_OSDisk
# - Az_OSDiskHCache               -> Disk Host Caching Setting     *** NEW ***
# - Az_OSDiskSize
# - Az_OSDiskTier                 -> Unmanaged/Managed...     [Modified]  
# - Az_OSDiskRepl                 -> Standard/Premium LRS/GRS/GRS-RA/...   
# - Az_DataDisks                  -> Display all data disks name attached to the VM
# - Az_DataDisksHCache            -> Disk Host Caching Setting     *** NEW ***
# - Az_DataDisksSize
# - Az_DataDisksTier              -> Unmanaged/Managed...     [Modified] 
# - Az_DataDisksRepl              -> Standard/Premium LRS/GRS/GRS-RA/...   
# - Az_VMTags                     -> List all VM tags in one field
# - Az_VMTag [0-14]               -> Make each VM tags it's own header in the Output
# -------------------------------------------------------------------------------------------------------------- 

Import-Module Azure 

# TO BE MODIFIED AS APPROPRIATE.  Currently start the file name with datetime stamp.  1 file per subscription
$OutputCSVPath = "c:\temp\" 
$OutputCSVFile = "{0:yyyyMMddHHmm}-AzureARMVMList" -f (Get-Date) 
$outputCSVExt  = ".csv" 
 
# Retreive Azure Module properties
"Validating installed PS Version and Azure PS Module version..."
$ReqVersions = Get-Module Azure -list | Select-Object Version, PowerShellVersion
# Current PoWershell version must be higher then the one required by the Azure Module
if($PSVersionTable.PSVersion.Major -lt $ReqVersions.PowerShellVersion.Major)
{
  $PSVerReq = $ReqVersions.PowerShellVersion
  $PSVerInst = $PSVersionTable.PSVersion
  "Validation failed..."
  "Installed PowerShell version: $PSVerInst"
  "Powershell version $PSVerReq required.  Please update the version of Powershell on this system"
  "Exiting Script"
  Break
} 
# Current script was tested with Azure module 4.0.0 
if($ReqVersions.Version.Major -lt 4) 
{
  $AZModuleInst = $ReqVersions.Version
  "Validation failed..."
  "Installed Azure PS Module: $AZModuleInst.  This script was tested with version 4.0.0"
  "Please update the Azure Powershell module..."
  "Download link: https://www.microsoft.com/web/handlers/webpi.ashx/getinstaller/WindowsAzurePowershellGet.3f.3f.3fnew.appids"
  "Exiting Script"
  Break
}

# Login to Azure Reaource Manager
Connect-AzAccount
 
Function GetDiskSize ($DiskURI) 
{ 
  # User running the script must have Read access to the VM Storage Accounts for these values to be retreive
  $error.clear() 
  $DiskContainer = ($DiskURI.Split('/'))[3]  
  $DiskBlobName  = ($DiskURI.Split('/'))[4]  
 
  # Create Return PS object
  $BlobObject = @{'Name'=$DiskURI;'SkuName'=" ";'SkuTier'=" ";'DiskSize'=0}

  # Avoid connecting to Storage if last disk in same Storage Account (Save significant time!) 
  if ($global:DiskSA -ne ((($DiskURI).Split('/')[2]).Split('.'))[0]) 
  { 
    $global:DiskSA = ((($DiskURI).Split('/')[2]).Split('.'))[0] 
    $global:SAobj = $AllARMSAs | where-object {$_.StorageAccountName -eq $DiskSA} 
    $SARG  = $global:SAobj.ResourceGroupName 
    $SAKeys     = Get-AzStorageAccountKey -ResourceGroupName $SARG -Name $DiskSA 
    $global:SAContext  = New-AzureStorageContext -StorageAccountName $DiskSA  -StorageAccountKey $SAKeys[0].value  
  } 

  $DiskObj = get-azurestorageblob -Context $SAContext -Container $DiskContainer -Blob $DiskBlobName 
  if($Error) 
    {   
       $BlobObject.DiskSize = -1  
       $error.Clear() 
    } 
  else 
    { 
      [int] $DiskSize = $Diskobj.Length/1024/1024/1024 # GB
      $BlobObject.DiskSize = $DiskSize
      $BlobObject.SkuName = $global:SAobj.Sku.Name
      $BlobObject.SkuTier = $global:SAobj.Sku.Tier 
    }  
 
  Return $BlobObject  

  trap { 
      Return $BlobObject 
    } 
} 
 
# Get Start Time 
$startDTM = (Get-Date) 
"Starting Script: {0:yyyy-MM-dd HH:mm}..." -f $startDTM 
 
# Get a list of all subscriptions (or a single subscription) 
"Retrieving all Subscriptions..." 
$Subscriptions = Get-AzSubscription | Sort SubscriptionName    
# ***  NOTE: Uncomment the following line if you want to limit the query to a specific subscription 
#$Subscriptions = Get-AzureRmSubscription | ? {$_.Name -eq "My Subscription"} 
"Found: " + $Subscriptions.Count 
 
# Retrieve all available Virtual Machine Sizes 
"`r`nRetrieving all available Virtual Machines Sizes..." 
$AllVMsSize = Get-AzVMSize -Location "West US"  #  Using West US and South Central US and East US 2 as those 2 locations are usually the ones with all and newer VM sizes 
$AllVMsSizeSCU = Get-AzVMSize -Location "South Central US" 
foreach ($VMsSizeSCU in $AllVMsSizeSCU) 
{ 
    if ($AllVMsSize.Name -notcontains $VMsSizeSCU.Name) { $AllVMsSize += $VMsSizeSCU } 
} 
$AllVMsSizeEU2s = Get-AzVMSize -Location "East US 2" 
foreach ($VMsSizeEU2 in $AllVMsSizeEU2s) 
{ 
    if ($AllVMsSize.Name -notcontains $VMsSizeEU2.Name) { $AllVMsSize += $VMsSizeEU2 } 
} 
"Found: " + $AllVMsSize.Count 
 
# Loop thru all subscriptions 
$AzureVMs = @() 
foreach($subscription in $Subscriptions)  
{ 
    $SubscriptionID = $Subscription.Id  
    $SubscriptionName = $Subscription.Name 
    "`r`nQuerying Subscription: $SubscriptionName ($SubscriptionID)" 
    Select-AzSubscription -SubscriptionId $SubscriptionID | Out-Null

    # Retrieve all Public IPs 
    "1- Retrieving all Public IPs..." 
    $AllPublicIPs = get-azpublicipaddress 
    "   Found: " + $AllPublicIPs.Count 
 
    # Retrieve all Virtual Networks 
    "2- Retrieving all Virtual Networks..." 
    $AllVirtualNetworks = get-azvirtualnetwork 
    "   Found: " + $AllVirtualNetworks.Count 
 
    # Retrieve all Network Interfaces 
    "3- Retrieving all Network Interfaces..." 
    $AllNetworkInterfaces = Get-AzNetworkInterface 
    "   Found: " + $AllNetworkInterfaces.Count 
  
    # Retrieve all ARM Virtual Machines 
    "4- Retrieving all ARM Virtual Machines..." 
    $AllARMVirtualMachines = get-azvm | Sort location,resourcegroupname,name 
    "   Found: " + $AllARMVirtualMachines.Count 
 
    # Skip further steps if no ARM VM found 
    if($AllARMVirtualMachines.Count -gt 0) 
    { 
 
        # Intitialize Storage Account Context variable 
        $global:DiskSA = "" 
 
        # Retrieve all ARM Storage Accounts 
        "5- Retrieving all ARM Storage Accounts..." 
        $AllARMSAs = Get-AzStorageAccount 
        "   Found: " + $AllARMSAs.Count 
 
        # Retrieve all Managed Disks 
        "6- Retrieving all Managed Disks..." 
        $AllMAnagedDisks = Get-AzDisk 
        "   Found: " + $AllManagedDisks.Count 

        # Retrieve all ARM Virtual Machine tags 
        "7- Capturing all ARM Virtual Machines Tags..." 
        $AllVMTags =  @() 
        foreach ($virtualmachine in $AllARMVirtualMachines) 
        { 
            $tags = $virtualmachine.Tags 
            $tKeys = $tags | select -ExpandProperty keys 
            foreach ($tkey in $tkeys) 
            { 
              
              if ($AllVMTags -notcontains $tkey.ToUpper()) { $AllVMTags += $tkey.ToUpper() } 
            } 
        } 
        "   Found: " + $AllVMTags.Count 
  
        # This script support up to 15 VM Tags, Increasing $ALLVMTags array to support up to 15 if less then 15 found 
        for($i=$($AllVMTags.Count);$i -lt 15; $i++) { $AllVMTags += "Az_VMTag$i"  } #Default Header value  
 
        # Capturing all ARM VM Configurations details 
        "8- Capturing all ARM VM Configuration Details...     (This may take a few minutes)" 
        $AzureVMs = foreach ($virtualmachine in $AllARMVirtualMachines) 
        { 
            $location = $virtualmachine.Location 
            $rgname = $virtualmachine.ResourceGroupName 
            $vmname = $virtualmachine.Name 
            $vmavzone = $virtualmachine.Zones[0]
 
            # Format Tags, sample: "key : Value <CarriageReturn> key : value "   TAGS keys are converted to UpperCase 
            $taglist = '' 
            $ThisVMTags = @(' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ')  # Array of VMTags matching the $AllVMTags (Header) 
            $tags = $virtualmachine.Tags 
            $tKeys = $tags | select -ExpandProperty keys 
            $tvalues = $tags | select -ExpandProperty values 
            if($tags.Count -eq 1)  
            { 
                  $taglist = $tkeys+":"+$tvalues 
                  $ndx = [array]::IndexOf($AllVMTags,$tKeys.ToUpper())  # Find position of header matching the Tag key 
                  $ThisVMTags[$ndx] = $tvalues 
            } 
            else 
              { 
                For ($i=0; $i -lt $tags.count; $i++)  
                { 
                  $tkey = $tkeys[$i] 
                  $tvalue = $tvalues[$i] 
                  $taglist = $taglist+$tkey+":"+$tvalue+"`n" 
                  $ndx = [array]::IndexOf($AllVMTags,$tKey.ToUpper())   # Find position of header matching the Tag key 
                  $ThisVMTags[$ndx] = $tvalue 
                } 
              } 
 
            # Get VM Status 
            $Status = get-azvm -Status -ResourceGroupName "$rgname" -Name "$vmname" 
            $vmstatus =  $Status.Statuses[1].DisplayStatus 
 
            # Get Availability Set 
            $AllRGASets = get-azavailabilityset -ResourceGroupName $rgname 
            $VMASet = $AllRGASets | Where-Object {$_.id -eq $virtualmachine.AvailabilitySetReference.Id} 
            $ASet = $VMASet.Name 
 
            # Get Number of Cores and Memory 
            $VMSize = $AllVMsSize | Where-object {$_.Name -eq $virtualmachine.HardwareProfile.VmSize}  
            $VMCores = $VMSize.NumberOfCores 
            $VMMem = $VMSize.MemoryInMB/1024 
 
            # Get VM Network Interface(s) and properties 
            $MatchingNic = "" 
            $NICName = @()
            $NICProvState = @() 
            $NICPrivateIP = @() 
            $NICPrivateAllocationMethod = @() 
            $NICVNet = @() 
            $NICSubnet = @() 
            foreach($vnic in $VirtualMachine.NetworkProfile.NetworkInterfaces) 
            { 
                $MatchingNic = $AllNetworkInterfaces | where-object {$_.id -eq $vnic.id} 
                $NICName += $MatchingNic.Name 
                $NICProvState += $MatchingNic.ProvisioningState
                $NICPrivateIP += $MatchingNic.IpConfigurations.PrivateIpAddress 
                $NICPrivateAllocationMethod += $MatchingNic.IpConfigurations.PrivateIpAllocationMethod 
                $NICSubnetID = $MatchingNic.IpConfigurations.Subnet.Id 
         
                # Identifying the VM Vnet 
                $VMVNet = $AllVirtualNetworks | where-object {$_.Subnets.id -eq $NICSubnetID } 
                $NICVnet += $VMVNet.Name 
 
                # Identifying the VM subnet 
                $AllVNetSubnets = $VMVNet.Subnets   
                $vmSubnet = $AllVNetSubnets | where-object {$_.id -eq $NICSubnetID }  
                $NICSubnet += $vmSubnet.Name 
 
                # Identifying Public IP Address assigned 
                $VMPublicIPID = $MatchingNic.IpConfigurations.PublicIpAddress.Id 
                $VMPublicIP = $AllPublicIPs | where-object {$_.id -eq $VMPublicIPID } 
                $NICPublicIP = $VMPublicIP.IPAddress 
                $NICPublicAllocationMethod = $VMPublicIP.PublicIpAllocationMethod 
 
            } 

            # Get VM OS Disk properties 
            $OSDiskName = '' 
            $OSDiskSize = 0
            $OSDiskRepl = '' 
            $OSDiskTier = ''
            $OSDiskHCache = ''  # Init/Reset

            # Get OS Disk Caching if set 
            $OSDiskHCache = $virtualmachine.StorageProfile.osdisk.Caching

            # Check if OSDisk uses Storage Account
            if($virtualmachine.StorageProfile.OsDisk.ManagedDisk -eq $null)
            {
                # Retreive OS Disk Replication Setting, tier (Standard or Premium) and Size 
                $VMOSDiskObj = GetDiskSize $virtualmachine.StorageProfile.OsDisk.Vhd.uri
                $OSDiskName = $VMOSDiskObj.Name 
                $OSDiskSize = $VMOSDiskObj.DiskSize
                $OSDiskRepl = $VMOSDiskObj.SkuName 
                $OSDiskTier = "Unmanaged"
            }
            else
            {
                $OSDiskID = $virtualmachine.StorageProfile.OsDisk.ManagedDisk.Id
                $VMOSDiskObj = $AllMAnagedDisks | where-object {$_.id -eq $OSDiskID }
                $OSDiskName = $VMOSDiskObj.Name 
                $OSDiskSize = $VMOSDiskObj.DiskSizeGB
                $OSDiskRepl = $VMOSDiskObj.AccountType
                $OSDiskTier = "Managed"
            }

            $AllVMDisksPremium = $true 
            if($OSDiskRepl -notmatch "Premium") { $AllVMDisksPremium = $false } 

            # Get VM Data Disks and their properties 
            $DataDiskObj = @()
            $VMDataDisksObj = @() 
            foreach($DataDisk in $virtualmachine.StorageProfile.DataDisks) 
            { 

              # Initialize variable before each iteration
              $VMDataDiskName = ''
              $VMDataDiskSize = 0
              $VMDataDiskRepl = ''
              $VMDataDiskTier = ''
              $VMDataDiskHCache = '' # Init/Reset 

              # Get Data Disk Caching if set 
              $VMDataDiskHCache = $DataDisk.Caching
              
              # Check if this DataDisk uses Storage Account
              if($DataDisk.ManagedDisk -eq $null)
              {
                # Retreive OS Disk Replication Setting, tier (Standard or Premium) and Size 
                $VMDataDiskObj = GetDiskSize $DataDisk.vhd.uri 
                $VMDataDiskName = $VMDataDiskObj.Name
                $VMDataDiskSize = $VMDataDiskObj.DiskSize
                $VMDataDiskRepl = $VMDataDiskObj.SkuName
                $VMDataDiskTier = "Unmanaged"
              }
              else
              {
                $DataDiskID = $DataDisk.ManagedDisk.Id
                $VMDataDiskObj = $AllMAnagedDisks | where-object {$_.id -eq $DataDiskID }
                $VMDataDiskName = $VMDataDiskObj.Name
                $VMDataDiskSize = $VMDataDiskObj.DiskSizeGB
                $VMDataDiskRepl = $VMDataDiskObj.AccountType
                $VMDataDiskTier = "Managed"
              }

              # Add Data Disk properties to arrray of Data disks object
              $DataDiskObj += @([pscustomobject]@{'Name'=$VMDataDiskName;'HostCache'=$VMDataDiskHCache;'Size'=$VMDataDiskSize;'Repl'=$VMDataDiskRepl;'Tier'=$VMDataDiskTier})

              # Check if this datadisk is a premium disk.  If not, set the all Premium disks to false (No SLA)
              if($VMDataDiskRepl -notmatch "Premium") { $AllVMDisksPremium = $false } 
            } 
 
            # Create custom PS objects and return all these properties for this VM 
            [pscustomobject]@{ 
                            Az_Location = $virtualmachine.Location 
                            Az_ResourceGroup = $virtualmachine.ResourceGroupName 
                            Az_Name = $virtualmachine.Name 
                            Az_Status = $vmstatus 
                            Az_Statuscode = $virtualmachine.StatusCode
                            AZ_AvZone = $vmavzone 
                            Az_AvSet = $ASet 
                            Az_Size = $virtualmachine.HardwareProfile.VmSize 
                            Az_Cores = $VMCores 
                            Az_Memory = $VMMem 
                            Az_OSType = $virtualmachine.StorageProfile.OsDisk.OsType 
                            Az_VNicNames = $NICName -join "`n" 
                            Az_VNicProvisioningState = $NICProvState -join "`n" 
                            Az_VNicPrivateIPs = $NICPrivateIP -join "`n" 
                            Az_vNicPrivateIPAllocMethods = $NICPrivateAllocationMethod -join "`n" 
                            Az_VirtualNetworks = $NICVnet -join "`n" 
                            Az_Subnets = $NICSubnet -join "`n" 
                            Az_VNicPublicIP = $NICPublicIP 
                            Az_VNicPublicIPAllocMethod = $NICPublicAllocationMethod 
                            Az_VM_Instance_SLA = $AllVMDisksPremium
                            Az_OSDisk = $OSDiskName 
                            Az_OSDiskHCache = $OSDiskHCache
                            Az_OSDiskSize = $OSDiskSize
                            Az_OSDiskTier = $OSDiskTier  
                            Az_OSDiskRepl = $OSDiskRepl 
                            Az_DataDisks = $DataDiskObj.Name -join "`n" 
                            Az_DataDisksHCache = $DataDiskObj.HostCache -join "`n" 
                            Az_DataDisksSize = $DataDiskObj.Size -join "`n" 
                            Az_DataDisksTier = $DataDiskObj.Tier -join "`n"
                            Az_DataDisksRepl = $DataDiskObj.Repl -join "`n"
                            Az_VMTags = $taglist 
                            $AllVMTags[0] = $ThisVMTags[0] 
                            $AllVMTags[1] = $ThisVMTags[1] 
                            $AllVMTags[2] = $ThisVMTags[2] 
                            $AllVMTags[3] = $ThisVMTags[3] 
                            $AllVMTags[4] = $ThisVMTags[4] 
                            $AllVMTags[5] = $ThisVMTags[5] 
                            $AllVMTags[6] = $ThisVMTags[6] 
                            $AllVMTags[7] = $ThisVMTags[7] 
                            $AllVMTags[8] = $ThisVMTags[8] 
                            $AllVMTags[9] = $ThisVMTags[9] 
                            $AllVMTags[10] = $ThisVMTags[10] 
                            $AllVMTags[11] = $ThisVMTags[11] 
                            $AllVMTags[12] = $ThisVMTags[12] 
                            $AllVMTags[13] = $ThisVMTags[13] 
                            $AllVMTags[14] = $ThisVMTags[14] 
                         } 
 
        }  #Array $AzureVMs 
 
        # Define CSV Output Filename, use subscription name and ID as name can be duplicate 
        $OutputCSV = "$OutputCSVPath$OutputCSVFile - $subscriptionName ($SubscriptionID)$outputCSVExt" 
 
        #CSV Exports Virtual Machines 
        "`r`nExporting Results to CSV file: $OutputCSV" 
          $CSVResult = $AzureVMs | Export-Csv $OutputCSV -NoTypeInformation 
    } 
    else 
      { "[Warning]: No ARM VMs found...  Skipping remaining steps."} 
}  # Subscriptions 
 
 
"`r`nCompleted!" 
 
# Get End Time 
$endDTM = (Get-Date) 
"Stopping Script: {0:yyyy-MM-dd HH:mm}..." -f $endDTM 
 
# Echo Time elapsed 
"Elapsed Time: $(($endDTM-$startDTM).totalseconds) seconds" 
 
# Catch any unexpected error occurring while running the script 
trap { 
    Write-Host "An unexpected error occurred....  Please try again in a few minutes..."   
    Write-Host $("`Exception: " + $_.Exception.Message);  
    Exit 
 } 
 
<#
    .SYNOPSIS
        Updates elastic search on multiple client/data/master nodes.
    .DESCRIPTION
        This script is invoked from the local box and uses user's credentials to connect with azure. It updates all nodes in parallel. It requires AzureRM cmdlet, installation instructions are available at https://docs.microsoft.com/en-us/powershell/azure/install-azurerm-ps?view=azurermps-6.4.0
    .PARAMETER resourceGroupName
        Resource group where ES cluster is deployed e.g. es-cluster-group
    .PARAMETER elasticSearchVersion
        Version of elasticsearch after update e.g. 6.3.1
    .PARAMETER discoveryEndpoints
        Formatted string of the allowed subnet addresses for unicast internode communication e.g. 10.0.0.4-3 is expanded to [10.0.0.4,10.0.0.5,10.0.0.6]
    .PARAMETER elasticClusterName
        Name of the elasticsearch cluster
    .EXAMPLE
        .\elasticsearch-windows-update.ps1 -subscriptionId azure-subscription-id -resourceGroupName es-cluster-group -elasticSearchVersion 6.3.1 -discoveryEndpoints 10.0.0.4-5 -elasticClusterName elasticsearch -elasticSearchBaseFolder elasticsearch  -dataNodes 3
		Updates ES version to 6.3.1
#>
Param(
    [string]$subscriptionId,
    [Parameter(Mandatory=$true)][string]$resourceGroupName,
    [Parameter(Mandatory=$true)][string]$elasticSearchVersion,
    [string]$elasticSearchBaseFolder,
    [string]$discoveryEndpoints,
    [string]$elasticClusterName,
    [Parameter(Mandatory=$true)][int]$dataNodes,
    [int]$masterNodes = 3,
    [int]$clientNodes = 3
)

function Log-Output(){
    $args | Write-Host -ForegroundColor Cyan
}

function Log-Error(){
    $args | Write-Host -ForegroundColor Red
}

Set-Alias -Name lmsg -Value Log-Output -Description "Displays an informational message in green color" 
Set-Alias -Name lerr -Value Log-Error -Description "Displays an error message in red color" 

function Update-ElasticSearch($vmName, $nodeType, $scriptPath)
{
    $parameters = @{
        "elasticSearchVersion" = "$elasticSearchVersion";
        "elasticSearchBaseFolder" = "$elasticSearchBaseFolder";
        "discoveryEndpoints" = "$discoveryEndpoints";
        "elasticClusterName" = "$elasticClusterName";
        "masterOnlyNode" = ($nodeType -eq "master");
        "clientOnlyNode" = ($nodeType -eq "client");
        "dataOnlyNode" = ($nodeType -eq "data");
        "update" = $true
    }
    
    lmsg "Invoke-AzureRmVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $parameters"
    $job = Invoke-AzureRmVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $parameters -AsJob
    return $job
}


function Get-VmInfoByType($nodeType, $nodes)
{
    $vmsInfo = @()
    for ($i = 0; $i -lt $nodes; $i++)
    {
        $vmsInfo += @{
            "Name" = "elasticsearch-$nodeType-vm$i";
            "NodeType" = $nodeType;
            "JobName" = "$nodeType-vm$i"
        }
    }
    
    return $vmsInfo;
}

function Get-AllVmsInfo()
{
    $clientVmNames = Get-VmInfoByType "client" $clientNodes
    $masterVmNames = Get-VmInfoByType "master" $masterNodes
    $dataVmNames = Get-VmInfoByType "data" $dataNodes
    return $clientVmNames + $masterVmNames + $dataVmNames
}

function Update-ElasticSearchCluster()
{
    lmsg "Starting update"
    
    $vmsInfo = Get-AllVmsInfo
    
    $count = $vmsInfo.Count
    $jobIds = @()
    
    lmsg "VMs to update: $count"
    
    $updateScriptPath = Join-Path $PSScriptRoot -ChildPath "elasticsearch-windows-install.ps1"
    
    for ($i = 0; $i -lt $count; $i++)
    {
        $vmName = $vmsInfo[$i].Name
        $nodeType = $vmsInfo[$i].NodeType
        
        lmsg "Starting job for $vmName"
        $job = Update-ElasticSearch $vmName $nodeType $updateScriptPath
        $job
        
        $jobIds += $job.Id
    }
    
    # Wait for all jobs to complete
    While (Get-Job -State "Running" -Id $jobIds)
    {
        $completed = (Get-Job -State "Completed" -Id $jobIds).Count
        
        lmsg "$completed/$count jobs completed. Sleeping for 15 seconds."
        Start-Sleep 15
    }

    $completed = (Get-Job -State "Completed").Count
    lmsg "$completed/$count jobs completed."
    
    # Get info about finished jobs
    lmsg "Get Jobs"
    Get-Job -Id $jobIds
    
    lmsg "Receive Jobs"
    Get-Job -Id $jobIds | Receive-Job
}

function Login
{
    $needLogin = $true
    Try 
    {
        $content = Get-AzureRmContext
        if ($content) 
        {
            $needLogin = ([string]::IsNullOrEmpty($content.Account))
        } 
    } 
    Catch 
    {
        if ($_ -like "*Login-AzureRmAccount to login*") 
        {
            $needLogin = $true
        } 
        else 
        {
            throw
        }
    }

    if ($needLogin)
    {
        Login-AzureRmAccount
    }
    
    Select-AzureRmSubscription -SubscriptionId $subscriptionId
}

# Login
#Connect-AzureRmAccount -Subscription $subscriptionId
# Login-AzureRmAccount
# Select-AzureRmSubscription -SubscriptionId $subscriptionId 
Login

# Update
Update-ElasticSearchCluster
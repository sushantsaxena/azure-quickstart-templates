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
        .\elasticsearch-windows-update.ps1 -subscriptionId azure-subscription-id -resourceGroupName es-cluster-group -elasticSearchVersion 6.3.1 -discoveryEndpoints 10.0.0.4-5 -elasticClusterName elasticsearch -dataNodes 3
        Installs 1.7.2 version of elasticsearch with cluster name evilescluster and 5 allowed subnet addresses from 4 to 8. Sets up the VM as master node.
    .EXAMPLE
        elasticSearchVersion 1.7.3 -elasticSearchBaseFolder software -elasticClusterName evilescluster -discoveryEndpoints 10.0.0.3-4 -dataOnlyNode
        Installs 1.7.3 version of elasticsearch with cluster name evilescluster and 4 allowed subnet addresses from 3 to 6. Sets up the VM as data node.
#>
Param(
    [string]$subscriptionId,
    [Parameter(Mandatory=$true)][string]$resourceGroupName,
    [Parameter(Mandatory=$true)][string]$elasticSearchVersion,
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

# Declare as variable as it needs to be passed to background jobs
$updateElasticSearchFunction = {
    function Update-ElasticSearch($resourceGroupName, $vmName, $nodeType, $scriptPath)
    {
        $parameters = @{
            "elasticSearchVersion" = "$elasticSearchVersion";
            "discoveryEndpoints" = "$discoveryEndpoints";
            "elasticClusterName" = "$elasticClusterName";
            "masterOnlyNode" = ($nodeType -eq "master");
            "clientOnlyNode" = ($nodeType -eq "client");
            "dataOnlyNode" = ($nodeType -eq "data");
            "update" = $true
        }
        Invoke-AzureRmVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $parameters
    }
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
    lmsg "VMs to update: $count"
    
    $updateScriptPath = Join-Path $PSScriptRoot -ChildPath "elasticsearch-windows-install.ps1"
    
    for ($i = 0; $i -lt $count; $i++)
    {
        $vmName = $vmsInfo[$i].Name
        $nodeType = $vmsInfo[$i].NodeType
        $jobName = $vmsInfo[$i].JobName
        
        lmsg "Starting job for $vmName"
        Start-Job -InitializationScript $updateElasticSearchFunction -Name "$jobName" -ScriptBlock {
            param ([string]$resourceGroupName, [string]$vmName, [string]$nodeType, [string]$scriptPath)
            Update-ElasticSearch $resourceGroupName $vmName $nodeType $scriptPath
        } -ArgumentList ($resourceGroupName, $vmName, $nodeType, $updateScriptPath)
    }
    
    # Wait for all jobs to complete
    While (Get-Job -State "Running")
    {
        $completed = (Get-Job -State "Completed").Count
        
        Get-Job
        lmsg "$completed/$count jobs completed. Sleeping for 15 seconds."
        Start-Sleep 15
    }

    $completed = (Get-Job -State "Completed").Count
    lmsg "$completed/$count jobs completed."
    
    # Get info about finished jobs
    lmsg "Get Jobs"
    Get-Job
    
    lmsg "Receive Jobs"
    Get-Job | Receive-Job
}

# Login
Connect-AzureRmAccount -Subscription $subscriptionId

# Update
Update-ElasticSearchCluster
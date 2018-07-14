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
    [string]$jdkInstallLocation,
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
    # $pass = ConvertTo-SecureString -string $password -AsPlainText -Force
    # $cred = New-Object -typename System.Management.Automation.PSCredential -argumentlist $username, $pass
    $parameters = @{
        "elasticSearchVersion" = "$elasticSearchVersion";
        "elasticSearchBaseFolder" = "$elasticSearchBaseFolder";
        "jdkInstallLocation" = "$jdkInstallLocation";
        "discoveryEndpoints" = "$discoveryEndpoints";
        "elasticClusterName" = "$elasticClusterName";
        "update" = $true
    }
    
    if ($nodeType -eq "master")
    {
        $parameters["masterOnlyNode"] = $true
    }    
    elseif ($nodeType -eq "client")
    {
        $parameters["clientOnlyNode"] = $true
    }
    
    if ($nodeType -eq "data")
    {
        $parameters["dataOnlyNode"] = $true
    }
    
    $masterOnlyNode = $nodeType -eq "master"
    $clientOnlyNode = $nodeType -eq "client"
    $dataOnlyNode = $nodeType -eq "data"

    if ($Debug)
    {
        lmsg "Invoke-AzureRmVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $parameters -Verbose -Debug"
        Invoke-AzureRmVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $parameters -Verbose -Debug
    }
    else
    {
        lmsg "Invoke-AzureRmVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $parameters -Verbose -AsJob"
        $job = Invoke-AzureRmVMRunCommand -ResourceGroupName $resourceGroupName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $parameters -Verbose -AsJob
        return $job
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
    
    if ($jdkInstallLocation.Length -eq 0) { $jdkInstallLocation = '"Program Files\Java\Jdk"' }
    
    $vmsInfo = Get-AllVmsInfo
    
    $count = $vmsInfo.Count
    $jobIds = @()
    $jobIdsToVmMap = @{}
    
    lmsg "VMs to update: $count"
    
    $updateScriptPath = Join-Path $PSScriptRoot -ChildPath "elasticsearch-windows-install.ps1"
    
    for ($i = 0; $i -lt $count; $i++)
    {
        $vmName = $vmsInfo[$i].Name
        $nodeType = $vmsInfo[$i].NodeType
        
        lmsg "Starting job for $vmName"
        
        $job = Update-ElasticSearch $vmName $nodeType $updateScriptPath
        
        if (-Not $Debug)
        {
            $job
            
            $jobIds += $job.Id
            $jobIdsToVmMap[$job.Id] = $vmName
        }
    }
    
    if ($Debug)
    {
        exit
    }
    
    # Wait for all jobs to complete
    While (Get-Job -State "Running" | Where-Object { $jobIds -contains $_.Id})
    {
        $completed = (Get-Job -State "Completed" | Where-Object { $jobIds -contains $_.Id}).Count
        
        lmsg "$completed/$count jobs completed. Sleeping for 15 seconds."
        Start-Sleep 15
    }

    $completed = (Get-Job -State "Completed" | Where-Object { $jobIds -contains $_.Id}).Count
    lmsg "$completed/$count jobs completed."
    
    # Get info about finished jobs
    lmsg "Get Jobs"
    Get-Job | Where-Object { $jobIds -contains $_.Id}
    
    lmsg "Receive Jobs"
    Get-Job | Where-Object { $jobIds -contains $_.Id} | Receive-Job
    
    $failedJobs = Get-Job -State "Failed" | Where-Object { $jobIds -contains $_.Id}
    $failedJobsCount = $failedJobs.Count
    if ($failedJobsCount -gt 0)
    {
        lmsg "Getting Failed jobs"
        foreach ($job in $failedJobs)
        {
            $vmName = $jobIdsToVmMap[$job.Id]
            lerr "Failed for $vmName"
            Receive-Job $job
        }
    }
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
Login

# Update
Update-ElasticSearchCluster
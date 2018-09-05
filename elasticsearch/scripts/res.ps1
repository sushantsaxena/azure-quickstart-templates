# To set the env vars permanently, need to use registry location
Set-Variable regEnvPath -Option Constant -Value 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment'
$logsFile = "C:\Downloads\Logs.txt"
$errorsFile = "C:\Downloads\Errors.txt"

function Log-Output(){
    $args | Write-Host -ForegroundColor Cyan
    if ($logsFile.Length -ne 0)
    {
        Add-Content -Path $logsFile -Value $args
    }
}

function Log-Error(){
    $args | Write-Host -ForegroundColor Red
    
    if ($errorsFile.Length -ne 0)
    {
        Add-Content -Path $errorsFile -Value $args
    }
}

Set-Alias -Name lmsg -Value Log-Output -Description "Displays an informational message in green color" 
Set-Alias -Name lerr -Value Log-Error -Description "Displays an error message in red color" 

function SetEnv-JavaHome($jdkInstallLocation)
{
    $homePath = $jdkInstallLocation
    
    lmsg "Setting JAVA_HOME in the registry to $homePath..."
    Set-ItemProperty -Path $regEnvPath -Name JAVA_HOME -Value $homePath | Out-Null
    
    lmsg 'Setting JAVA_HOME for the current session...'
    Set-Item Env:JAVA_HOME "$homePath" | Out-Null

    # Additional check
    if ([environment]::GetEnvironmentVariable("JAVA_HOME","machine") -eq $null)
    {
        [environment]::setenvironmentvariable("JAVA_HOME",$homePath,"machine") | Out-Null
    }

    lmsg 'Modifying path variable to point to java executable...'
    $currentPath = (Get-ItemProperty -Path $regEnvPath -Name PATH).Path
    $currentPath = $currentPath + ';' + "$homePath\bin"
    Set-ItemProperty -Path $regEnvPath -Name PATH -Value $currentPath
    Set-Item Env:PATH "$currentPath"
}

function ElasticSearch-StartService()
{
    # Check if the service is installed and start it
    $elasticService = (get-service | Where-Object {$_.Name -match 'elasticsearch'}).Name
    if($elasticService -ne $null)
    {
        lmsg 'Starting elasticsearch service...'
        Start-Service -Name $elasticService | lmsg
        $svc = Get-Service | Where-Object { $_.Name -Match 'elasticsearch'}
        
        if($svc -ne $null)
        {
            $svc.WaitForStatus('Running', '00:00:10')
        }

        lmsg 'Setting the elasticsearch service startup to automatic...'
        Set-Service $elasticService -StartupType Automatic | Out-Null
    }
    else
    {
        lmsg "Elasticsearch service not found"
    }
}
function ElasticSearch-StopService()
{
    # Check if the service is installed and start it
    $elasticService = (get-service | Where-Object {$_.Name -match 'elasticsearch'}).Name
    if($elasticService -ne $null)
    {
        lmsg 'Stopping elasticsearch service...'
        Stop-Service -Name $elasticService | lmsg
        $svc = Get-Service | Where-Object { $_.Name -Match 'elasticsearch'}
        
        if($svc -ne $null)
        {
            $svc.WaitForStatus('Stopped', '00:00:10')
        }
    }
    else
    {
        lmsg "Elasticsearch service not found"
    }
}

function Install-Jdk
{
    param(
        [Parameter(Mandatory=$true)]
        [string]$sourceLoc,
        [Parameter(Mandatory=$true)]
        [string]$targetDrive
    )

    $installPath = "$targetDrive`:\Program Files\Java\Jdk"

    $homefolderPath = (Get-Location).Path
    $logPath = "$homefolderPath\java_install_log.txt"
    $psLog = "$homefolderPath\java_install_ps_log.txt"
    $psErr = "$homefolderPath\java_install_ps_err.txt"

    try{
        lmsg "Installing java on the box under $installPath..."
        $proc = Start-Process -FilePath $sourceLoc -ArgumentList "/s INSTALLDIR=`"$installPath`" AUTO_UPDATE=0 /L `"$logPath`"" -Wait -PassThru -RedirectStandardOutput $psLog -RedirectStandardError $psErr -NoNewWindow
        $proc.WaitForExit()
        lmsg "JDK installed under $installPath" "Log file location: $logPath"
        
        #if($proc.ExitCode -ne 0){
            #THROW "JDK installation error"
        #}
        
    }catch [System.Exception]{
        lerr $_.Exception.Message
        lerr $_.Exception.StackTrace
        Break
    }
    
    return $installPath
}

function SetEnv-HeapSize
{
    # Obtain total memory in MB and divide in half
    $halfRamCnt = [math]::Round(((Get-WmiObject Win32_PhysicalMemory | measure-object Capacity -sum).sum/1mb)/2,0)
    $halfRamCnt = [math]::Min($halfRamCnt, 31744)
    $halfRam = $halfRamCnt.ToString() + 'm'
    lmsg "Half of total RAM in system is $halfRam mb."
    
	$javaOpts = "-Xms$halfRam -Xmx$halfRam"
	lmsg "Setting ES_JAVA_OPTS in the registry to $javaOpts..."
	Set-ItemProperty -Path $regEnvPath -Name ES_JAVA_OPTS -Value $javaOpts | Out-Null

	lmsg 'Setting ES_JAVA_OPTS for the current session...'
	Set-Item Env:ES_JAVA_OPTS $javaOpts | Out-Null

	# Additional check
	if ([environment]::GetEnvironmentVariable("ES_JAVA_OPTS","machine") -eq $null)
	{
		[environment]::setenvironmentvariable("ES_JAVA_OPTS",$javaOpts,"machine") | Out-Null
	}
}


SetEnv-JavaHome "C:\Program Files\Java\Jdk"
SetEnv-HeapSize

# if (Test-Path "C:\Program Files\Java\Jdk\bin")
# {
	# lmsg "Java present"
	# exit
# }

lmsg "Stopping ES service"
ElasticSearch-StopService

lmsg "Removing Java"
Remove-Item "C:\Program Files\Java\Jdk" -Recurse

# CHANGE THIS TO DOWNLOAD FROM BLOB
lmsg "Installing Java"
Install-Jdk "C:\Downloads\Java\jdk-8u65-windows-x64.exe" "C"

lmsg "Removing ES service"
$elasticSearchServiceFile = "C:\elasticSearch\elasticsearch-6.3.1\bin\elasticsearch-service.bat"
cmd.exe /C "$elasticSearchServiceFile remove"

lmsg "Installing ES service"
cmd.exe /C "$elasticSearchServiceFile install"

ElasticSearch-StartService



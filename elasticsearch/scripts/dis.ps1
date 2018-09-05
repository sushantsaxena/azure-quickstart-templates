
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

function Disable-WindowsUpdate()
{
    $windowsUpdateService = Get-Service -Name "wuauserv"
    if ($windowsUpdateService -ne $null)
    {
        if ($windowsUpdateService.Status -ne "Stopped")
        {
            lmsg 'Stopping Windows Update Service...'
            Stop-Service -Name "wuauserv" | lmsg
            
            $svc = Get-Service -Name "wuauserv"
            if($svc -ne $null)
            {
                $svc.WaitForStatus('Stopped', '00:00:10')
            }
        }
        else
        {
            lmsg 'Windows Update Service already stopped'
        }
        
        lmsg 'Setting the Windows Update Service startup to disabled'
        Set-Service -Name "wuauserv" -StartupType Disabled | lmsg
    }
    else
    {
        lmsg "No Windows Update Service found"
    }
}

Disable-WindowsUpdate
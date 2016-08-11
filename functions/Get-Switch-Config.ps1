
$ErrorActionPreference = SilentlyContinue

Function Get-Switch-Config { 
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$True, ValueFromPipeline=$True)]
        [string[]]$RemoteHosts,
        [switch]$Prompt,
        [string]$Password,
        [string]$RootPath = "K:\System_Teknisk\Powershell Script\TFTP",
        [string]$LogPath = "$RootPath\get-config_$(Get-Date -format "dd.MM.yyyy hh.mm.ss").log",
        [string]$OutPath = ".\",
        [string]$Prog = "$rootPath\tftpd64.exe",
        [string]$Port = "23",
        [int]$WaitTime = 200,
        [switch]$NoLog,
        [switch]$Silent,
        [switch]$OverWrite
    )
    #region BEGIN
    $TempFolder = "R"
    cd $RootPath

    if (@($RemoteHosts)[0] -match "@") {
        Write-Verbose "Reading from file"
        $Path = (Resolve-Path "$(@($RemoteHosts)[0])".Substring(1)).Path
        $RemoteHosts = Get-Content $Path
    }

    if ($input) {
        $RemoteHosts = $input | ? { "$_" -notmatch "^#.+" }
    }
    $RemoteHostCount = @($RemoteHosts).Length

    if (!$Silent) { 
        Write-Host -NoNewline "Starting download from $RemoteHostCount switch" 
        if ($RemoteHostCount -ne 1){
            Write-Host "es."
        } else {
            Write-Host "."
        }
    }
    
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

    if ($Prompt -or ! ($Password)) {
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
        $log += "$("@\@$OutPath@\@".PadRight(75)) | "

        if (! $Silent) {
            Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 0 `
                -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Testing connection."
        }

        if (! (Test-Connection -count 1 -ComputerName $RemoteHost -quiet)) {
            $log += "0 FAILURE 0: Could not see host."
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

        if (! $Silent) {
            Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 10 `
                -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Setting up connection."
        }

        If ($Socket) {
            if (! $Silent) {
                Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 20 `
                    -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Connected."
            }

            # Declare required variables and objects
            $Stream = $Socket.GetStream()
            $Writer = New-Object System.IO.StreamWriter($Stream)
            $Buffer = New-Object System.Byte[] 1024
            $Encoding = New-Object System.Text.ASCIIEncoding

            # Wait for switch to produce welcome screen
            Start-Sleep -Milliseconds ($WaitTime * 2)
            
            if (! $Silent) {
                Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 30 `
                    -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Reading input stream."
            }

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

            # Making a temporary short name because switches have a limit to output length
            $OutNameFull = $OutputFile

            $OutputFile = "$RemoteHost $Date.pcc" -replace " ", "_"

            #endregion

            if (! $Silent) {
            Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 40 `
                    -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Finding login prompt."
            }

            #region Find Login Prompt
            # Send an enter keypress if unable to find login
            if (! ("$Result" -match "[uU]sername")) {
                Write-Verbose "Did not find login form, attempting to bypass Any Key prompt..."
                $Writer.Write("~")
                $Writer.Flush()
                Start-Sleep -Milliseconds ($WaitTime * 4)
            } else {
                Start-Sleep -Milliseconds $WaitTime
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
                    $log += "0 FAILURE 1: Unable to find login prompt."        
                    $SessionLog += "$log" + "`r`n"
                    continue
                }
            }
            #endregion

            if (! $Silent) {
                Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 50 `
                    -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Logging in."
            }

            # Issue commands to log in
            Write-Verbose ("Trying to log in with Admin")
            ForEach($Command in $Commands) {
                $Writer.WriteLine($Command)
                $Writer.Flush()
                Start-Sleep -Milliseconds $WaitTime
            }

            # Verifying if password was correct
            While ($Stream.DataAvailable) {
                $Read = $Stream.Read($Buffer, 0, 1024)
                $Result += ($Encoding.GetString($Buffer, 0, $Read))
            }
            if ("$Result" -match "[Ii]nvalid password") {
                Write-Verbose ("Trying to log in with Manager")
                ForEach($Command in @("Manager", "$pass")) {
                    $Writer.WriteLine($Command)
                    $Writer.Flush()
                    Start-Sleep -Milliseconds $WaitTime
                }
                While ($Stream.DataAvailable) {
                    $Read = $Stream.Read($Buffer, 0, 1024)
                    $Result = ($Encoding.GetString($Buffer, 0, $Read))
                }
                if ("$Result" -match "[Ii]nvalid password") {
                    Write-Host "WARNING: Password incorrect!"
                    $log += "0 FAILURE 2: Password incorrect."
                    $SessionLog += "$log" + "`r`n"
                    continue
                }
            }
            
            #region Find Console
            # Get to command line if older switch
            While ($Stream.DataAvailable) {
                $Read = $Stream.Read($Buffer, 0, 1024)
                $Result += ($Encoding.GetString($Buffer, 0, $Read))
            }
            if (! ("$Result" -match "#")) {
                Write-Verbose "Can't find console, trying to access it."
                if ("$Result" -match "y\/n") {
                    $Writer.Write("y")
                    $Writer.Flush()
                }
                Start-Sleep -Milliseconds $WaitTime
                $Writer.Write("~")
                $Writer.Flush()
                Start-Sleep -Milliseconds $WaitTime
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
                $log += "0 FAILURE 3: Could not find console."
                $SessionLog += "$log" + "`r`n"
                continue
            }
            #endregion

            if (! $Silent) {
                Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 60 `
                    -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Starting Download."
            }

            # Start download of config file
            Write-Verbose ("Downloading")

            $Writer.WriteLine("copy running-config tftp $LocalIP `"$TempFolder\$OutputFile`"")
            $Writer.Flush()

            # Give the program some time to transfer the file
            for($i=1; $i -le 12; $i++){
                #Write-Host -NoNewline "."
                if (! (Test-Path "$RootPath\$TempFolder\$OutputFile")){
                    Start-Sleep -Milliseconds $WaitTime
                }
                if (! $Silent) {
                    Write-Progress -Activity "Downloading Configuration Files" -PercentComplete (65 + ($i * 2)) `
                        -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Downloading."
                }
            }

            # Report whether file has been downloaded
            if (Test-Path ("$RootPath\$TempFolder\$OutputFile")) {
                $log += "1 SUCCESS : File has been received."
                Write-Verbose "Success!"
            } else {
                $log += "0 FAILURE 4: Could not download file."
                Write-Verbose "Could not download."
            }

            if (! $OverWrite -and $OutPath -ne ".\") {
                # Move old config file to .\OLD\ folder
                if (! (Test-Path "$OutPath\OLD")) {
                    Write-Verbose "Making OLD-folder"
                    md "$OutPath\OLD" | Out-Null
                }
                Write-Verbose "Attempting to move $OutPath\$RemoteHost* to $OutPath\OLD\"
                Move-Item "$OutPath\$RemoteHost*" "$OutPath\OLD" -Force
            }
            # Move file to correct location
            Write-Verbose "Attempting to move $RootPath\$TempFolder\$OutputFile -> $OutPath"
            Move-Item "$RootPath\$TempFolder\$OutputFile" "$(Resolve-Path $OutPath)\$OutNameFull" -Force
            if (Test-Path "$(Resolve-Path $OutPath)\$OutNameFull") {
                Write-Verbose "Success"
            } else {
                Write-Verbose "Failure"
            }

            # Issue commands for graceful termination of telnet session
            if (! $Silent) {
                Write-Progress -Activity "Downloading Configuration Files" -PercentComplete 90 `
                    -Status "Switch $count/$RemoteHostCount" -CurrentOperation "Exiting switch."
            }
            Write-Verbose "Exiting"
            ForEach($Command in $ExitCommands) {
                $Writer.WriteLine($Command)
                $Writer.Flush()
                #Write-Host -NoNewline "."
                Start-Sleep -Milliseconds $WaitTime
            }
        } else {
            $log += "0 FAILURE 0: Could not establish connection to $RemoteHost`:$Port."
        }

        $SessionLog += "$log" + "`r`n"
    }
    #endregion PROCESS
    #region END

    if (! $Silent) { Write-Host "Done." }

    if (! $NoLog) {
        $SessionLog | Out-File $LogPath -Append
    }

    #endregion END
}

# Get-Content switches.txt | Get-Switch-Config

# Get-Switch-Config -RemoteHosts "10.11.5.77" -OutPath "Foo\BAR" -Verbose

# Get-Switch-Config -RemoteHosts "@Foo\BAR\switches.txt" -OutPath ".\Foo\BAR" -Prompt
<#
$tftpPath = "K:\System_Teknisk\Powershell Script\TFTP"

if (! (Test-Path $tftpPath)) {
    Write-Host "Cannot find tftp path! IT should be $tftpPath. Make sure it's visible and try again."
    pause
    exit
} else {
    cd $tftpPath
}

if (! (Test-Path "old_logs")) {
    md "old_logs" | Out-Null
}

$pass = Read-Host -AsSecureString "Please Enter Password "
# Convert secure password to one that can be issued to switch
$pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))

Move-Item "get-config*" "old_logs\" -Force

ForEach ($path in (gci . -Directory -Recurse | % { gci $_.FullName -File -Filter "switches.txt" }).FullName) {
    Get-Switch-Config -RemoteHosts "@$path" -OutPath $(Split-Path $path) -Password $pass -WaitTime 100
}

Write-Host "Retrying with longer wait time..."
$failures = @((gci | select-string "0 FAILURE [^0]").Line)
Write-Host "Retrying $($failures.Length) switches."
ForEach ($line in $failures) {
    $RemoteHost = $line -replace ":.+", ""
    $Path = "$(([regex]::Match($line, "(?<=@\\@).+(?=@\\@)")).Value)"
    Get-Switch-Config -RemoteHosts $RemoteHost -OutPath $Path -LogPath "get-config_RETRIES.log" -Password $pass -Silent
}

# Trim blank lines
(gc .\get-config_RETRIES.log | ? { $_.trim() -ne "" }) | set-content .\get-config_RETRIES.log

$failures = @(gc .\get-config_RETRIES.log | select-string "0 FAILURE [^0]")
Write-Host -NoNewline "Done. "
if ($failures.Length -gt 0) {
    Write-Host "$($failures.Length) switches were reachable but could not download."
} else {
    Write-Host "All reachable hosts produced config."
}

#((gci | select-string "0 FAILURE [^0]").Line -replace ":.+", "") | Get-Switch-Config -WaitTime 300 -Password $pass -NoLog

(gci | select-string "3 WARNING").Line | Out-File "get-config_WARNINGS.log"
(gci | select-string "0 FAILURE").Line | Out-File "get-config_FAILURES.log"

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


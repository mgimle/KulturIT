#requires -version 4

$ErrorActionPreference = "SilentlyContinue"

clear-host

# importing the function
. "K:\System_Teknisk\Powershell Script\functions\Get-Switch-Config.ps1"

$TftpPath = "K:\System_Teknisk\Powershell Script\TFTP\tftpd64.exe"
$RootPath = "K:\Dokumentasjon\10 MuseumsIT\Nettverk\Konfigfiler - Automatisk Backup"
$WaitTime = 150
$AutoTries = 4
$SearchRoot = "$RootPath\Konfigfiler"
$LogDir = "$RootPath\logs"
$Structure = "$RootPath\structure.txt"

$FailLog = "$LogDir\get-config_FAILURES.log"

if (! (Test-Path $RootPath)) {
    Write-Host "Cannot find root path! It should be `"$TftpPath`". Make sure it's available and try again."
    pause
    exit
}

if (! (Test-Path $TftpPath)) {
    Write-Host "Cannot find tftp path! It should be `"$TftpPath`". Make sure it's available and try again."
    pause
    exit
}

if (! (Test-Path $LogDir)) {
    md $LogDir | Out-Null
    md "$LogDir\old_logs" | Out-Null
}

$Selection = -1
$MenuOptions = 0..3
$Menu = @"
    0 : Complete Config Backup
    1 : Single Config Backup
    2 : Retry Failed Switches
    3 : Reconstruct structure table
"@

Write-Host "Welcome to Auto Config Downloader by Michael HG"
Write-Host $Menu
while (! ($MenuOptions -contains $Selection)) {
    $Selection = Read-Host "Please select an option "
}

if (0..1 -contains $Selection) {
    # Start TFTP program and terminate if firewall is blocking
    if (! (ps | ? { $_.Path -eq $TftpPath })) { & $TftpPath }

    $FirewallRule = (Get-NetFirewallRule "TCP*skimh*tftpd*")
    if(! ($FirewallRule.Enabled -and $FirewallRule.Action -eq "Allow")){
        Write-Host "Firewall is blocking TFTPD64.EXE! The program cannot run if this is the case."
        pause
        exit
    }
}

# Making a simple file contain the information that would require a lot of data from the remote file server if it were to be
# executed every time the program is run.
if ($Selection -eq 3) {
    Write-Host "Reconstructing structure table..."
    (gci $SearchRoot -Directory -Recurse -Exclude "OLD" | % { (gci $_ | ? { $_.Extension -match "pcc" }).FullName }) > "$RootPath\structure.txt"
    Write-Host "Done."
    pause
    exit
}

if ($Selection -eq 2) {
    if (! (Test-Path "$LogDir\$FailLog")) {
        Write-Host "Could not find failure log."
        pause
        exit
    }
    $Failures = @(gc "$LogDir\$FailLog")
    if (! $Failures) {
        Write-Host "Faillog contains no entries."
        pause
        exit
    }
    $AutoTries = 0
}

$Pass = Read-Host -AsSecureString "Please Enter Password "
# Convert secure password to one that can be issued to switch
$Pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))

# Moving the old logs
if ($Selection -eq 0) {
    Write-Host "Moving Old Logs..."
    Move-Item "$LogDir\get-config*" "$LogDir\old_logs\" -Force
    Write-Host "Done."
}

# Writing the total amount of switches that will be downloaded from
if ($Selection -ne 1) { Write-Host "Detecting switches..." }
if ($Selection -eq 0) {
    $Totalswitches = (((gci -Recurse $SearchRoot -Filter "switches.txt") | % { gc $_.FullName }) | Measure-Object -Line).Lines
} elseif ($Selection -eq 2) {
    $Totalswitches = $Failures.Length
}

if ($Selection -eq 0 -or $Selection -eq 2){
    Write-Host -NoNewLine "Starting download from $Totalswitches switch"
    if ($Totalswitches -gt 1){
        Write-Host "es."
    } else {
        Write-Host "."
    }
}

# COMPLTE BACKUP
if ($Selection -eq 0) {
    # Go through all of the switches.txt and output the log file in the same directory
    ForEach ($Path in (gci $SearchRoot -Directory -Recurse | % { gci $_.FullName -File -Filter "switches.txt" }).FullName) {
        Get-Switch-Config -RemoteHosts "@$Path" -OutPath "$(Split-Path $Path)" -Password "$Pass" -RootPath $RootPath -Prog $TftpPath `
        -LogPath "$LogDir\get-config_$(Get-Date -format "dd.MM.yyyy hh.mm.ss")_$(Split-Path (Split-Path $Path -Parent) -Leaf).log" -WaitTime $WaitTime
    }
} 
# SINGLE BACKUP
elseif ($Selection -eq 1) {
    $RemoteHost = ""
    while (! $RemoteHost) {
        $RemoteHost = Read-Host "Please enter switch IP "
        if (! (Test-Connection -count 1 -ComputerName $RemoteHost -quiet)) {
            Write-Host "Could not find switch! Please make sure the IP is correct. ($RemoteHost)"
            $RemoteHost = ""
        }
    }
    Write-Host "Trying to determine target location of config..."
    Start-Sleep -Milliseconds 500
    try {
        $DirNames = @(Split-Path (gc "$RootPath\structure.txt" | ? { $_ -match "$RemoteHost`_" }))
    } catch { $Path = "" }
    if ($DirNames.Length -ne 1) { $Path = "" } else { $Path = $DirNames[0] }
    if (! $Path) {
        Write-Host "Could not determine target location. "
        $Path = "$RootPath"
        Write-Host "Outputting Config into root dir."
    } else {
        Write-Host "Success; Outputting in $Path"
    }
    $Command = Read-Host "Would you like to open dir when done? [y/n]"
    $Command = ($Command -match "y")
    
    $LogPath = "$LogDir\get-config-$(Get-Date -format "dd.MM.yyyy hh.mm.ss")_SINGLE_$RemoteHost.log"
    Get-Switch-Config -RemoteHosts "$RemoteHost" -OutPath "$Path" -Password "$Pass" `
        -LogPath "$LogPath" -WaitTime ($WaitTime * 3) -RootPath $RootPath -Prog $TftpPath
    
    gc $LogPath

    if ($Command) {
        Write-Host "Opening config folder"
        explorer $Path
    }
    pause
    exit
}

# Retrying the switches that did not get read correctly on the first pass. Retrying $AutoTries times with increasing delay
$Continue = $true
while ($Continue) {
    $WaitTime = $WaitTime + 150
    $RetryLog = "$LogDir\get-config_RETRIES-$WaitTime MS.log"

    Write-Host "Retrying with longer wait time... ($WaitTime ms)"
    if(! $Failures) { $Failures = @((gci $LogDir | select-string "0 FAILURE [^0]").Line) }
    Write-Host "Retrying $($Failures.Length) switches."
    $Count = 0
    ForEach ($Line in $Failures) {
        $Count++
        Write-Progress -Activity "Downloading configs..." -PercentComplete (100 * ($Count / $Failures.Length)) `
            -Status "Switch $Count/$($Failures.Length)"
        $RemoteHost = $Line -replace ":.+", ""
        $Path = "$(([regex]::Match($Line, "(?<=@\\@).+(?=@\\@)")).Value)" # Getting output path from log
        Get-Switch-Config -RemoteHosts "$RemoteHost" -OutPath "$Path" -RootPath $RootPath -Prog $TftpPath `
            -LogPath "$RetryLog" -Password "$Pass" -Silent -WaitTime $WaitTime
    }

    # Trim blank lines from retries log
    (gc "$RetryLog" | ? { $_.trim() -ne "" }) | set-content "$RetryLog"

    $Failures = @(gc "$RetryLog" | select-string "0 FAILURE [^0]")
    Write-Host -NoNewline "Done. "
    if ($Failures.Length -gt 0) {
        Write-Host "$($Failures.Length) switches were reachable but could not download."
        if ($AutoTries -gt 0) {
            $AutoTries--               
        } else {
            $Command = Read-Host "Retry with longer wait? (y/n)"
            if ("$Command" -match "n") { $Continue = $false }
        }
    } else {
        Write-Host "All reachable hosts produced config."
        $Continue = $false
    }
}

(gci $LogDir | select-string "3 WARNING").Line | Out-File "$LogDir\get-config_WARNINGS.log"
(gci $LogDir | select-string "0 FAILURE 0").Line | Out-File "$LogDir\get-config_COULD_NOT_REACH.log"
(gc (gci "$LogDir\get-config_RETRIES*.log" | sort LastWriteTime | select -last 1) | select-string "0 FAILURE").Line | Out-File "$LogDir\$FailLog"

pause

$IPRegex = "(\d{1,3}\.){3}\d{1,3}"
$MACRegex = "([A-F0-9]{2}-?){6}"

$success = $false
while (-Not $success) {
    Clear-Host
    Write-Host ("Welcome to Remote Information Sniffer by Michael HG")
    
    $hostname = Read-Host "Please enter desired host name (l for localhost) "
    if ($hostname -eq "l") {
        $hostname = "127.0.0.1"
    }
    $hostname = $hostname.ToUpper()

    Write-Host ("`nConnecting to host " + $hostname + "...`n")
    if (-Not (Test-Connection -count 2 -computername $hostname -quiet)) { #-quiet tag reduces function to only return a single Boolean
        Write-Host ("Could not reach host! Please try again.")
        pause
    } else { 
        $success = $true
    }
}

if ([regex]::Match($hostname, $IPRegex).Success){
	$hostip = $hostname
} else {
	$hostip = ([regex]::Match((nslookup $hostname)[4], $IPRegex)).value
	Write-Host ("Resolved IP. " + $hostname + " has IP " + $hostip + "`n")
}
Start-Sleep -m 500 # Small delay for visual flow
Write-Host ("Success! Connected to " + $hostname + ".`n")


$separator = "- - - - - - - -"

Write-Host ($separator)
# Temporarily storing data in a variable in order to present it at the same time as title.
$i = (wmic /node:$hostip bios get serialnumber)[1..2]
Write-Host ("Serial Number")
$i
Write-Host ($separator)
$i = (wmic /node:$hostip /namespace:\\root\wmi path MS_SystemInformation get SystemSKU)[1..2]
Write-Host ("Product Number")
$i
Write-Host ($separator)
(wmic /node:$hostip computersystem get model"," name"," manufacturer"," systemtype)[0..2] # Quoted commas necessary for the get to be valid on certain systems
Write-Host ($separator)


$macstrings = getmac /s $hostname /v /fo csv 
$adapterpriority = "Wi-Fi", "Ethernet", "Lokal", "Local"
foreach ($adapter in $adapterpriority) {
    $macstring = $macstrings | select-string $adapter
    if ("$macstring".length -gt 0) {
        break
    }
}
$macinfo = "$macstring".Split(",").replace("`"", "")
$infonames = $macstrings[0].split(",") # Headers
$infonames = $infonames.replace("`"", "").PadRight(20)
for ($i=0; $i -le 2; $i++){
    Write-Host ($infonames[$i] + $macinfo[$i])
}
Write-Host ($separator)
Write-Host ("Copyable MAC : ".PadRight(20) + (([regex]::Match($macstring, $MACRegex)).value -replace '-', '').ToLower())
Write-Host ($separator)
pause

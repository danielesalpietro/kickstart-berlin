#requires -RunAsAdministrator
<#
boot-test-hyperv.ps1 - equivalente Hyper-V di boot-test-qemu.sh.

Crea una VM Gen2 throwaway, avvia l'ISO autoinstall, cattura la console
seriale via named pipe (richiede console=ttyS0 nel kernel, gia' presente
nell'ISO generata da build-iso.sh) e verifica il login SSH con la chiave
iniettata a build-time. Ripulisce la VM e il VHD al termine.

Uso:
  scripts/boot-test-hyperv.ps1 -Iso build\kickstart-berlin-test.iso -SshKey $env:USERPROFILE\.ssh\ks_test_key
#>
param(
    [Parameter(Mandatory=$true)][string]$Iso,
    [Parameter(Mandatory=$true)][string]$SshKey,
    [string]$VmName = "ks-berlin-boottest-$([guid]::NewGuid().ToString('N').Substring(0,8))",
    [int]$TimeoutSec = 5400,
    [int]$MemoryGB = 4,
    [int]$DiskGB = 20,
    [string]$SwitchName = "Default Switch",
    [int]$SshPort = 22
)

$ErrorActionPreference = "Stop"
$isoPath = (Resolve-Path $Iso).Path
$buildDir = Split-Path $isoPath -Parent
$vhdPath = Join-Path $buildDir "$VmName.vhdx"
$pipeName = "ks-berlin-$VmName"
$logPath = Join-Path $buildDir "$VmName.serial.log"

function Log($msg) { Write-Host "[boot-test-hyperv] $msg" }

function Cleanup {
    Log "Pulizia: rimuovo VM e VHD throwaway..."
    if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $vhdPath) { Remove-Item $vhdPath -Force -ErrorAction SilentlyContinue }
}

try {
    Log "Creo VM '$VmName' (Gen2, ${MemoryGB}GB RAM, disco ${DiskGB}GB, switch '$SwitchName')..."
    New-VM -Name $VmName -MemoryStartupBytes ($MemoryGB * 1GB) -Generation 2 `
        -NewVHDPath $vhdPath -NewVHDSizeBytes ($DiskGB * 1GB) -SwitchName $SwitchName | Out-Null
    Set-VMProcessor -VMName $VmName -Count 4
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
    Add-VMDvdDrive -VMName $VmName -Path $isoPath
    $dvd = Get-VMDvdDrive -VMName $VmName
    Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd
    Set-VMComPort -VMName $VmName -Number 1 -Path "\\.\pipe\$pipeName"

    Log "Avvio VM..."
    Start-VM -Name $VmName

    # Lettore console seriale in background: connette alla pipe e scrive su file.
    $readerJob = Start-Job -ScriptBlock {
        param($pipeName, $logPath)
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::In)
        $pipe.Connect(60000)
        $reader = New-Object System.IO.StreamReader($pipe)
        $fs = [System.IO.File]::Open($logPath, 'Create', 'Write', 'ReadWrite')
        $writer = New-Object System.IO.StreamWriter($fs)
        $writer.AutoFlush = $true
        $buffer = New-Object char[] 4096
        while ($true) {
            $read = $reader.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) { $writer.Write($buffer, 0, $read) }
        }
    } -ArgumentList $pipeName, $logPath

    Log "Attendo completamento autoinstall e login SSH (timeout ${TimeoutSec}s)..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sshOk = $false
    $lastHeartbeat = 0

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 15

        $ip = (Get-VMNetworkAdapter -VMName $VmName).IPAddresses |
              Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1

        if ($ip) {
            $sshTest = & ssh -p $SshPort -i $SshKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
                -o ConnectTimeout=5 -o BatchMode=yes admin@$ip 'echo HYPERV_SSH_OK' 2>$null
            if ($sshTest -match 'HYPERV_SSH_OK') {
                $sshOk = $true
                Log "Login SSH riuscito su $ip! Autoinstall completato senza prompt."
                break
            }
        }

        if (($sw.Elapsed.TotalSeconds - $lastHeartbeat) -ge 60) {
            $lastHeartbeat = $sw.Elapsed.TotalSeconds
            $lastLine = if (Test-Path $logPath) { (Get-Content $logPath -Raw -ErrorAction SilentlyContinue) -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1 } else { "(nessun output seriale ancora)" }
            $ipDisplay = if ($ip) { $ip } else { "n/d" }
            Log ("... ancora in attesa ({0}s/{1}s) IP={2} - ultima riga seriale: {3}" -f [int]$sw.Elapsed.TotalSeconds, $TimeoutSec, $ipDisplay, $lastLine)
        }
    }

    Stop-Job $readerJob -ErrorAction SilentlyContinue
    Remove-Job $readerJob -ErrorAction SilentlyContinue

    if (-not $sshOk) {
        Log "TIMEOUT: autoinstall/SSH non completato entro ${TimeoutSec}s. Ultime righe seriali:"
        if (Test-Path $logPath) { Get-Content $logPath -Tail 60 }
        exit 1
    }

    Log "Test superato."
    exit 0
}
finally {
    Cleanup
}

#requires -RunAsAdministrator
<#
boot-test-hyperv.ps1 - equivalente Hyper-V di boot-test-qemu.sh.

Crea una VM Gen2 throwaway, avvia l'ISO autoinstall, cattura la console
seriale via named pipe (richiede console=ttyS0 nel kernel, gia' presente
nell'ISO generata da build-iso.sh) e verifica il login SSH con la chiave
iniettata a build-time. Con -Disks 2 crea due VHD di dimensione diversa
(sistema piu' piccolo, datastore piu' grande) per testare la topologia
dual-disk della Fase 2 (issue #2) - a differenza di boot-test-qemu.sh
--disks 2, che oggi crea dischi tutti della stessa taglia e quindi non
verifica davvero l'euristica "disco piu' piccolo = sistema" di
iso/storage-dual-disk.yaml. Ripulisce VM e VHD al termine.

Uso (1 disco, invariato):
  scripts/boot-test-hyperv.ps1 -Iso build\kickstart-berlin-test.iso -SshKey $env:USERPROFILE\.ssh\ks_test_key

Uso (2 dischi di dimensione diversa, Fase 2):
  scripts/boot-test-hyperv.ps1 -Iso build\kickstart-berlin-test.iso -SshKey $env:USERPROFILE\.ssh\ks_test_key `
      -Disks 2 -DiskGB 20 -DiskGB2 40
  # L'ISO deve essere stata generata con "build-iso.sh --disks 2" (topologia dual).
#>
param(
    [Parameter(Mandatory=$true)][string]$Iso,
    [Parameter(Mandatory=$true)][string]$SshKey,
    [string]$VmName = "ks-berlin-boottest-$([guid]::NewGuid().ToString('N').Substring(0,8))",
    [int]$TimeoutSec = 5400,
    [int]$MemoryGB = 4,
    [ValidateSet(1, 2)][int]$Disks = 1,
    [int]$DiskGB = 20,
    [int]$DiskGB2 = 40,
    [string]$SwitchName = "Default Switch",
    [int]$SshPort = 22,
    [string]$DatastoreMountRoot = "/grastorp/volumes",
    [string]$DatastoreSymlinkName = "datastore",
    [string]$DatastoreFilesystem = "xfs"
)

if ($Disks -eq 2 -and $DiskGB -eq $DiskGB2) {
    throw "-DiskGB e -DiskGB2 sono uguali (${DiskGB}GB): la topologia dual-disk assegna il sistema al disco " +
          "piu' piccolo (match: size: smallest in iso/storage-dual-disk.yaml) - dischi di taglia identica " +
          "non testano quell'euristica. Usa due valori diversi."
}

$ErrorActionPreference = "Stop"
$isoPath = (Resolve-Path $Iso).Path
$buildDir = Split-Path $isoPath -Parent
$vhdPath = Join-Path $buildDir "$VmName.vhdx"
$vhdPath2 = Join-Path $buildDir "$VmName-datastore.vhdx"
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
    if (Test-Path $vhdPath2) { Remove-Item $vhdPath2 -Force -ErrorAction SilentlyContinue }
}

try {
    Log "Creo VM '$VmName' (Gen2, ${MemoryGB}GB RAM, $Disks disco/i, switch '$SwitchName')..."
    New-VM -Name $VmName -MemoryStartupBytes ($MemoryGB * 1GB) -Generation 2 `
        -NewVHDPath $vhdPath -NewVHDSizeBytes ($DiskGB * 1GB) -SwitchName $SwitchName | Out-Null
    Set-VMProcessor -VMName $VmName -Count 4
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off

    if ($Disks -eq 2) {
        Log "Aggiungo secondo VHD da ${DiskGB2}GB (datastore, atteso disco 'grande')..."
        New-VHD -Path $vhdPath2 -SizeBytes ($DiskGB2 * 1GB) -Dynamic | Out-Null
        Add-VMHardDiskDrive -VMName $VmName -Path $vhdPath2 -ControllerType SCSI
    }

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
    $vmIp = $null

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 15

        $ip = (Get-VMNetworkAdapter -VMName $VmName).IPAddresses |
              Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1

        if ($ip) {
            $sshTest = & ssh -p $SshPort -i $SshKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
                -o ConnectTimeout=5 -o BatchMode=yes admin@$ip 'echo HYPERV_SSH_OK' 2>$null
            if ($sshTest -match 'HYPERV_SSH_OK') {
                $sshOk = $true
                $vmIp = $ip
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

    # Verifica remota del Datastore (Fase 2, issue #2): il symlink deve risolvere
    # a un mountpoint reale del filesystem atteso. Stesso controllo di
    # boot-test-qemu.sh (findmnt sul target del symlink).
    $datastoreLink = "$DatastoreMountRoot/$DatastoreSymlinkName"
    $sshArgs = @('-p', $SshPort, '-i', $SshKey, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', "admin@$vmIp")
    $remoteCheck = "set -e; target=`$(readlink -f '$datastoreLink'); fstype=`$(findmnt -no FSTYPE --target `"`$target`"); [ `"`$fstype`" = '$DatastoreFilesystem' ]"
    & ssh @sshArgs $remoteCheck
    if ($LASTEXITCODE -ne 0) {
        Log "Datastore non montato correttamente su ${datastoreLink} (atteso fstype ${DatastoreFilesystem}) - diagnostica remota:"
        & ssh @sshArgs "lsblk -f; echo ---; findmnt; echo ---; ls -la '$DatastoreMountRoot'" 2>&1
        exit 1
    }
    Log "Datastore verificato: $datastoreLink montato come $DatastoreFilesystem."

    if ($Disks -eq 2) {
        # Verifica aggiuntiva specifica dual-disk: il disco di sistema (root) deve
        # essere quello piu' piccolo - conferma o smentisce l'euristica non ancora
        # validata segnalata in logbook-fase2.md.
        $rootSizeCheck = "lsblk -bno SIZE `$(findmnt -no SOURCE --target /) | head -1"
        $rootDiskBytes = & ssh @sshArgs $rootSizeCheck
        Log "Dimensione del device root riportata dalla VM: $rootDiskBytes byte (disco system atteso: ${DiskGB}GB, il piu' piccolo dei due)."
    }

    Log "Test superato."
    exit 0
}
finally {
    Cleanup
}

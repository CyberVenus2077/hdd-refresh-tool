$ErrorActionPreference = 'Continue'
$desk = [Environment]::GetFolderPath('Desktop')
$logE = Join-Path $desk "refresh_log_E.txt"
$stateE = Join-Path $desk "refresh_state_E.txt"
$monitor = Join-Path $desk "refresh_monitor_E.txt"
$script = Join-Path $desk "refresh_drive.ps1"
$driveRoot = 'E:\'

function Write-Mon($msg) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
  Add-Content -LiteralPath $monitor -Value $line -Encoding UTF8
}

function Get-TaskRunning {
  $p = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'refresh_drive' -and $_.CommandLine -notmatch 'monitor_refresh|guard' -and $_.CommandLine -notmatch 'Get-CimInstance' }
  return [bool]$p
}

function Is-Done {
  if (Test-Path $logE) {
    $last = Get-Content $logE -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($last -match 'ALL DONE') { return $true }
  }
  return $false
}

function Restart-Task {
  $log = Get-Content $logE -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 1
  Write-Mon "TASK DEAD, last_log=$log, restarting..."
  Start-Process powershell -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$script`"","-Root",$driveRoot -WindowStyle Normal
  Start-Sleep -Seconds 20
  if (Get-TaskRunning) {
    Write-Mon "RESTART OK"
  } else {
    Write-Mon "RESTART FAILED - will retry next cycle"
  }
}

Write-Mon "==== GUARD STARTED (auto-restart enabled) ===="
$missingCount = 0
while ($true) {
  if (Is-Done) {
    Write-Mon "ALL DONE detected - guard exiting"
    break
  }
  if (-not (Get-TaskRunning)) {
    $missingCount++
    Write-Mon "task not running (check #$missingCount)"
    if ($missingCount -ge 2) {
      Restart-Task
      $missingCount = 0
    }
  } else {
    $missingCount = 0
    $snap = Get-Counter "\PhysicalDisk(*)\Disk Bytes/sec" -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue |
      ForEach-Object { $_.CounterSamples | Where-Object { $_.InstanceName -match 'e:' } | Measure-Object CookedValue -Sum } |
      Select-Object -ExpandProperty Sum
    $units = 0
    if (Test-Path $stateE) { $units = (Get-Content $stateE -Encoding UTF8 -ErrorAction SilentlyContinue | Measure-Object).Count }
    $disk = if ($snap) { [math]::Round($snap/1MB,1) } else { 0 }
    Write-Mon "heartbeat: running, done_units=$units, disk=${disk}MB/s"
  }
  Start-Sleep -Seconds 300
}

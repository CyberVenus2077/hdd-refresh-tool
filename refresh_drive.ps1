param(
  [string]$Root
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$driveLetter = $Root.Substring(0, 1).ToUpper()
$LogFile = Join-Path $scriptDir "refresh_log_$driveLetter.txt"
$StateFile = Join-Path $scriptDir "refresh_state_$driveLetter.txt"
$tmpSuffix = '.__refresh_tmp__'

function Write-Log($msg) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Write-State($path) {
  Add-Content -LiteralPath $StateFile -Value $path -Encoding UTF8
}

function Restore-StrayTmp([string]$dir) {
  Get-ChildItem -LiteralPath $dir -Recurse -File -Filter "*$tmpSuffix" -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $orig = $_.FullName.Substring(0, $_.FullName.Length - $tmpSuffix.Length)
    try {
      if ([System.IO.File]::Exists($orig)) {
        [System.IO.File]::SetAttributes($orig, [IO.FileAttributes]::Normal)
        [System.IO.File]::Delete($orig)
      }
      [System.IO.File]::Move($_.FullName, $orig)
      Write-Log "RECOVER tmp->original: $($_.FullName)"
    } catch {
      Write-Log "RECOVER FAIL: $($_.FullName): $($_.Exception.Message)"
    }
  }
}

function Refresh-File($file) {
  $tmp = "$($file.FullName)$tmpSuffix"
  try {
    $fs = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
    $len = $fs.Length
    $fs.Close()
    if ($len -eq 0) { return 0 }
    if ([System.IO.File]::Exists($tmp)) {
      [System.IO.File]::SetAttributes($tmp, [IO.FileAttributes]::Normal)
      [System.IO.File]::Delete($tmp)
    }
    $wasRO = ($file.Attributes -band [IO.FileAttributes]::ReadOnly) -eq [IO.FileAttributes]::ReadOnly
    [System.IO.File]::Copy($file.FullName, $tmp, $true)
    $tl = [System.IO.FileInfo]::new($tmp).Length
    if ($tl -ne $len) { throw "size mismatch $tl != $len" }
    if ($wasRO) { [System.IO.File]::SetAttributes($file.FullName, [IO.FileAttributes]::Normal) }
    [System.IO.File]::Delete($file.FullName)
    [System.IO.File]::Move($tmp, $file.FullName)
    if ($wasRO) { [System.IO.File]::SetAttributes($file.FullName, [IO.FileAttributes]::ReadOnly) }
    return $len
  } catch {
    Write-Log "FAIL $($file.FullName): $($_.Exception.Message)"
    if ([System.IO.File]::Exists($tmp)) {
      [System.IO.File]::SetAttributes($tmp, [IO.FileAttributes]::Normal)
      [System.IO.File]::Delete($tmp)
    }
    return -1
  }
}

$topDirs = Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue
if (-not $topDirs) {
  [Console]::WriteLine("[ERROR] Cannot read $Root (maybe BitLocker locked or empty).")
  exit 1
}
$done = @()
if (Test-Path -LiteralPath $StateFile) { $done = Get-Content -LiteralPath $StateFile -Encoding UTF8 }

# ---- pre-scan total bytes for overall progress ----
Write-Log "SCAN total bytes..."
[Console]::WriteLine("Scanning total data size (this may take a moment)...")
$totalAll = 0
$topBytes = @{}
foreach ($d in $topDirs) {
  $sum = 0
  Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $sum += $_.Length }
  $topBytes[$d.FullName] = $sum
  $totalAll += $sum
}
$totalAllGB = [math]::Round($totalAll / 1GB, 1)
Write-Log "SCAN done total=$totalAllGB GB"
[Console]::WriteLine("Total data to refresh: $totalAllGB GB")
$doneAll = 0
$doneAllGB = 0.0

Write-Log "==== START v3 root=$Root topdirs=$($topDirs.Count) total=${totalAllGB}GB done_units=$($done.Count) ===="
[Console]::WriteLine("")

$tdIdx = 0
foreach ($d in $topDirs) {
  $tdIdx++
  if ($done -contains $d.FullName) {
    $skipGB = $topBytes[$d.FullName]
    $doneAll += $skipGB
    $doneAllGB = [math]::Round($doneAll / 1GB, 1)
    $pctAll = if ($totalAll -gt 0) { [math]::Round($doneAll * 100 / $totalAll, 1) } else { 100 }
    Write-Log "SKIP top(done): $($d.FullName)"
    [Console]::WriteLine("[SKIP] $($d.Name) (already done)  [OVERALL ${doneAllGB}GB / ${totalAllGB}GB ${pctAll}%]")
    continue
  }
  Write-Log "BEGIN top: $($d.FullName)"
  Restore-StrayTmp $d.FullName

  $direct = Get-ChildItem -LiteralPath $d.FullName -File -Force -ErrorAction SilentlyContinue
  $ok = 0; $fail = 0; $skip = 0
  foreach ($f in $direct) {
    $r = Refresh-File $f
    if ($r -eq 0) { $skip++ } elseif ($r -lt 0) { $fail++ } else { $ok++; $doneAll += $r }
  }
  if ($direct) {
    $doneAllGB = [math]::Round($doneAll / 1GB, 1)
    $pctAll = if ($totalAll -gt 0) { [math]::Round($doneAll * 100 / $totalAll, 1) } else { 100 }
    Write-Log "DONE direct(root files): $($d.FullName) ok=$ok fail=$fail skip=$skip [OVERALL ${doneAllGB}GB/${totalAllGB}GB ${pctAll}%]"
  }

  $subs = Get-ChildItem -LiteralPath $d.FullName -Directory -Force -ErrorAction SilentlyContinue
  $si = 0
  foreach ($s in $subs) {
    $si++
    if ($done -contains $s.FullName) {
      $skipSubGB = 0
      Get-ChildItem -LiteralPath $s.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $skipSubGB += $_.Length }
      $doneAll += $skipSubGB
      $doneAllGB = [math]::Round($doneAll / 1GB, 1)
      $pctAll = if ($totalAll -gt 0) { [math]::Round($doneAll * 100 / $totalAll, 1) } else { 100 }
      Write-Log "SKIP sub(done): $($s.FullName)"
      [Console]::WriteLine("  [SKIP] $($s.Name) (already done)  [OVERALL ${doneAllGB}GB / ${totalAllGB}GB ${pctAll}%]")
      continue
    }
    Write-Log "BEGIN sub: $($s.FullName)"
    Restore-StrayTmp $s.FullName

    $files = Get-ChildItem -LiteralPath $s.FullName -Recurse -File -Force -ErrorAction SilentlyContinue
    $totalBytes = 0
    foreach ($f in $files) { $totalBytes += $f.Length }
    $fileCount = $files.Count
    if ($fileCount -eq 0) {
      Write-Log "EMPTY sub: $($s.FullName)"
      [Console]::WriteLine("  [EMPTY] $($s.Name)")
      Write-State $s.FullName
      continue
    }
    Write-Log "PLAN sub=$($s.Name) files=$fileCount bytes=$totalBytes"

    $ok = 0; $fail = 0; $skip = 0; $doneBytes = 0; $fi = 0
    foreach ($f in $files) {
      $fi++
      $r = Refresh-File $f
      if ($r -eq 0) { $skip++ } elseif ($r -lt 0) { $fail++ } else { $ok++; $doneBytes += $r; $doneAll += $r }
      if (($fi % 5 -eq 0) -or $fi -eq $fileCount) {
        $pct = if ($totalBytes -gt 0) { [math]::Round($doneBytes * 100 / $totalBytes, 1) } else { 100 }
        $gs = [math]::Round($doneBytes / 1GB, 2)
        $gt = [math]::Round($totalBytes / 1GB, 2)
        $doneAllGB = [math]::Round($doneAll / 1GB, 1)
        $pctAll = if ($totalAll -gt 0) { [math]::Round($doneAll * 100 / $totalAll, 1) } else { 100 }
        [Console]::Write("`r  [OVERALL ${doneAllGB}GB / ${totalAllGB}GB ${pctAll}%]  [$tdIdx/$($topDirs.Count)] $($d.Name)/$($s.Name)  $fi/$fileCount files  ${gs}GB/$gt GB  ${pct}%    ")
      }
    }
    [Console]::WriteLine("")
    Write-Log "DONE sub: $($s.FullName) ok=$ok fail=$fail skip=$skip"
    Write-State $s.FullName
  }
  Write-Log "DONE top: $($d.FullName)"
  Write-State $d.FullName
}
Write-Log "==== ALL DONE root=$Root total=${totalAllGB}GB ===="
[Console]::WriteLine("")
[Console]::WriteLine("[DONE] All folders finished. Log: $LogFile")

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidateSet('Inspect', 'Install', 'Rollback')]
  [string]$Action = 'Inspect',
  [string]$HelperPath,
  [string]$ProfilePath = (Join-Path $PSScriptRoot '..\\profiles\\profile-win10-codex-26.1002.7124-sky-0.7.6.json')
)

$ErrorActionPreference = 'Stop'
$profile = Get-Content -Raw -LiteralPath $ProfilePath | ConvertFrom-Json

function Get-Sha256([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Convert-Hex([string]$Value) {
  if (($Value.Length % 2) -ne 0 -or $Value -notmatch '^[0-9a-fA-F]*$') { throw 'Invalid profile hex value.' }
  $bytes = New-Object byte[] ($Value.Length / 2)
  for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Value.Substring($i * 2, 2), 16) }
  return ,$bytes
}

function Resolve-Helper([string]$RequestedPath) {
  if ($RequestedPath) {
    if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) { throw 'The requested helper file does not exist.' }
    return (Get-Item -LiteralPath $RequestedPath).FullName
  }

  $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
  $matches = @()
  if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
    foreach ($runtime in Get-ChildItem -LiteralPath $runtimeRoot -Directory) {
      $skyRoot = Join-Path $runtime.FullName 'bin\node_modules\@oai\sky'
      $manifest = Join-Path $skyRoot 'package.json'
      $candidate = Join-Path $skyRoot 'bin\windows\codex-computer-use.exe'
      if ((Test-Path -LiteralPath $manifest -PathType Leaf) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $sky = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
        if ($sky.version -eq $profile.skyVersion) { $matches += Get-Item -LiteralPath $candidate }
      }
    }
  }
  if ($matches.Count -ne 1) { throw "Expected one @oai/sky $($profile.skyVersion) helper in the current-user runtime; found $($matches.Count). Pass -HelperPath to select an exact file." }
  return $matches[0].FullName
}

function Assert-Profile([byte[]]$Bytes, [string]$State) {
  foreach ($region in $profile.patchRegions) {
    $expected = Convert-Hex $(if ($State -eq 'Original') { $region.original } else { $region.patched })
    if ($region.offset + $expected.Length -gt $Bytes.Length) { throw "Patch region exceeds helper size: $($region.name)" }
    for ($i = 0; $i -lt $expected.Length; $i++) {
      if ($Bytes[$region.offset + $i] -ne $expected[$i]) { throw "Profile byte check failed at $($region.name); no file was changed." }
    }
  }
}

$resolvedHelper = Resolve-Helper $HelperPath
$originalHash = ([string]$profile.originalSha256).ToLowerInvariant()
$patchedHash = ([string]$profile.patchedSha256).ToLowerInvariant()
$currentBytes = [IO.File]::ReadAllBytes($resolvedHelper)
$currentHash = Get-Sha256 $currentBytes
$backup = Join-Path (Join-Path $env:USERPROFILE '.codex\backups\computer-use-helper') "$($profile.desktopVersion)-sky-$($profile.skyVersion)-$($originalHash.Substring(0, 8))\codex-computer-use.exe.original"

if ($Action -eq 'Inspect') {
  $state = if ($currentHash -eq $originalHash) { 'original-patchable' } elseif ($currentHash -eq $patchedHash) { 'patched' } else { 'unsupported' }
  [pscustomobject]@{ State = $state; SkyVersion = $profile.skyVersion; OriginalSha256 = $originalHash; CurrentSha256 = $currentHash; PatchedSha256 = $patchedHash }
  return
}

$windowsBuild = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
if ($windowsBuild -ne 19045) { throw 'Installation and rollback are restricted to Windows 10 build 19045.' }

if ($Action -eq 'Install') {
  if ($currentHash -eq $patchedHash) { Assert-Profile $currentBytes 'Patched'; Write-Output 'This exact helper is already patched.'; return }
  if ($currentHash -ne $originalHash) { throw 'Unknown helper hash. This profile refuses to modify it.' }
  Assert-Profile $currentBytes 'Original'
  if ($PSCmdlet.ShouldProcess($resolvedHelper, 'Install exact-hash Windows 10 capture profile')) {
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
      New-Item -ItemType Directory -Path (Split-Path $backup) -Force | Out-Null
      [IO.File]::WriteAllBytes($backup, $currentBytes)
    }
    if ((Get-Sha256 ([IO.File]::ReadAllBytes($backup))) -ne $originalHash) { throw 'Verified original backup is missing or has the wrong hash.' }
    $candidate = [byte[]]$currentBytes.Clone()
    foreach ($region in $profile.patchRegions) {
      $replacement = Convert-Hex $region.patched
      [Array]::Copy($replacement, 0, $candidate, [int]$region.offset, $replacement.Length)
    }
    if ((Get-Sha256 $candidate) -ne $patchedHash) { throw 'Candidate output hash mismatch; no helper file was changed.' }
    $staging = $resolvedHelper + '.repair-' + [Guid]::NewGuid().ToString('N')
    try {
      [IO.File]::WriteAllBytes($staging, $candidate)
      $running = @(Get-Process -Name 'codex-computer-use' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.Equals($resolvedHelper, [StringComparison]::OrdinalIgnoreCase) })
      foreach ($process in $running) {
        Stop-Process -Id $process.Id -Force
        if (-not $process.WaitForExit(5000)) { throw "Capture helper $($process.Id) did not exit." }
      }
      [IO.File]::Replace($staging, $resolvedHelper, [NullString]::Value)
      if ((Get-Sha256 ([IO.File]::ReadAllBytes($resolvedHelper))) -ne $patchedHash) { throw 'Installed output hash mismatch.' }
      Write-Output 'Exact profile installed. Restart Computer Use and verify a visible window capture.'
    } finally {
      if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force }
    }
  }
  return
}

if ($currentHash -eq $originalHash) { Write-Output 'The exact original helper is already installed.'; return }
if ($currentHash -ne $patchedHash) { throw 'Unknown helper hash. Rollback refused.' }
if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Sha256 ([IO.File]::ReadAllBytes($backup))) -ne $originalHash) { throw 'The exact original backup is missing or invalid.' }
Assert-Profile $currentBytes 'Patched'
if ($PSCmdlet.ShouldProcess($resolvedHelper, 'Restore verified original capture helper')) {
  $staging = $resolvedHelper + '.restore-' + [Guid]::NewGuid().ToString('N')
  try {
    Copy-Item -LiteralPath $backup -Destination $staging
    $running = @(Get-Process -Name 'codex-computer-use' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.Equals($resolvedHelper, [StringComparison]::OrdinalIgnoreCase) })
    foreach ($process in $running) {
      Stop-Process -Id $process.Id -Force
      if (-not $process.WaitForExit(5000)) { throw "Capture helper $($process.Id) did not exit." }
    }
    [IO.File]::Replace($staging, $resolvedHelper, [NullString]::Value)
    if ((Get-Sha256 ([IO.File]::ReadAllBytes($resolvedHelper))) -ne $originalHash) { throw 'Restored output hash mismatch.' }
    Write-Output 'Verified original helper restored.'
  } finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force }
  }
}

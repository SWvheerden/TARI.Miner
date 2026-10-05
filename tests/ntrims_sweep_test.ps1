$ErrorActionPreference = 'Stop'
# Dry-run regressions for tools\ntrims_sweep.ps1: parsing, stop rules, choice
# and failure handling, using tests\ntrims_sweep_fake_solver.py instead of a
# GPU. tests/ntrims_sweep_test.sh runs the same cases against the bash sweep.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$sweepScript = Join-Path (Join-Path $root 'tools') 'ntrims_sweep.ps1'
$psExe = (Get-Process -Id $PID).Path
$python = $env:PYTHON
if (-not $python) { $python = 'python' }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'tari-c29-ntrims-sweep-test-' + [Guid]::NewGuid().ToString('N')
)
$script:checks = 0
$script:failures = 0

function Fail-Check {
    param([string]$Message)
    [Console]::Error.WriteLine("FAIL: $Message")
    $script:failures++
}

# Runs a dry-run sweep; output in $tempRoot\Name.
function Invoke-Sweep {
    param([string]$Name, [string]$Scenario, [string[]]$Extra = @(), [switch]$NoDryRun,
          [string]$Arch = 'sm_89')
    $env:TARI_FAKE_SOLVER_SCENARIO = $Scenario
    $env:TARI_FAKE_SOLVER_STATE = Join-Path $tempRoot "$Name.state"
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sweepScript,
        '-Arch', $Arch, '-Runs', '3', '-Python', $python, '-Out', (Join-Path $tempRoot $Name))
    if (-not $NoDryRun) { $arguments += '-DryRun' }
    $arguments += $Extra
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & $psExe @arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return [pscustomobject]@{ Code = $code; Output = ($output -join "`n") }
}

function Expect-Choice {
    param([string]$Name, [string]$Scenario, [string]$Chosen, [string[]]$Extra = @())
    $script:checks++
    $result = Invoke-Sweep -Name $Name -Scenario $Scenario -Extra $Extra
    if ($result.Code -ne 0) {
        Fail-Check "${Name}: sweep failed`n$($result.Output)"
    } elseif ($result.Output -notmatch "(?m)^chosen_ntrims=$Chosen\s*$") {
        Fail-Check "${Name}: expected chosen_ntrims=$Chosen`n$($result.Output)"
    }
    return $result
}

function Expect-Row {
    param([string]$Name, [int]$Ntrims, [string]$Text)
    $script:checks++
    $lines = [IO.File]::ReadAllLines((Join-Path (Join-Path $tempRoot $Name) 'sweep.md'))
    $row = $lines | Where-Object { $_.StartsWith("| sm_89 | $Ntrims |") }
    if (-not $row -or -not $row.Contains($Text)) {
        Fail-Check "${Name}: row $Ntrims lacks [$Text]: $row"
    }
}

function Expect-Failure {
    param([string]$Name, [string]$Scenario, [string]$Message, [string[]]$Extra = @(), [switch]$NoDryRun,
          [string]$Arch = 'sm_89')
    $script:checks++
    $result = Invoke-Sweep -Name $Name -Scenario $Scenario -Extra $Extra -NoDryRun:$NoDryRun -Arch $Arch
    if ($result.Code -eq 0) {
        Fail-Check "${Name}: sweep should have failed"
    } elseif (-not $result.Output.Contains($Message)) {
        Fail-Check "${Name}: expected [$Message]`n$($result.Output)"
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Remove-Item Env:TARI_ARCH_FLAGS -ErrorAction SilentlyContinue

    $edges = Expect-Choice -Name 'edges' -Scenario 'edges' -Chosen '42' -Extra @('-DefaultNtrims', '50')
    Expect-Row 'edges' 50 '| 13.650 | 13.650 13.650 13.650 | +0.00% |'
    Expect-Row 'edges' 50 '| default |'
    Expect-Row 'edges' 48 '| no gain |'
    Expect-Row 'edges' 46 '| gain |'
    Expect-Row 'edges' 42 '| **chosen** |'
    Expect-Row 'edges' 40 'stop: max edges 556939 > 524288'
    Expect-Row 'edges' 36 'not run (stopped above)'
    $csv = [IO.File]::ReadAllLines((Join-Path (Join-Path $tempRoot 'edges') 'sweep.csv'))
    $script:checks++
    # 6 measured ntrims (50 to 40), 3 full runs and one 2-core run each, plus the header.
    if ($csv.Count -ne 25) { Fail-Check "edges: expected 25 CSV lines, got $($csv.Count)" }
    $script:checks++
    if (-not ($csv | Where-Object { $_.StartsWith('sm_89,44,2core,1,13.773,82387,164775,296595,329550,') })) {
        Fail-Check 'edges: 2-core CSV row for 44'
    }
    $script:checks++
    if (-not $edges.Output.Contains('--candidate-ntrims 42')) { Fail-Check 'edges: recall command' }
    $script:checks++
    if ($edges.Output -notmatch '(?m)^   -DTARI_C29_DEFAULT_NTRIMS=42\s*$') { Fail-Check 'edges: flags line' }

    $null = Expect-Choice -Name 'overflow' -Scenario 'overflow' -Chosen '46' -Extra @('-DefaultNtrims', '50')
    Expect-Row 'overflow' 44 'stop: OOPS or NODE OVERFLOW'

    $null = Expect-Choice -Name 'busy' -Scenario 'busy' -Chosen '40' -Extra @('-DefaultNtrims', '50')
    Expect-Row 'busy' 36 'stop: 2-core busy 0.4500 > 0.40'
    Expect-Row 'busy' 40 '| 35.0% / 35.0% |'

    $null = Expect-Choice -Name 'nogain' -Scenario 'nogain' -Chosen 'none' -Extra @('-DefaultNtrims', '50')
    Expect-Row 'nogain' 42 '| no gain |'

    # 48 has the best median but one run below the default's median.
    $null = Expect-Choice -Name 'noisy' -Scenario 'noisy' -Chosen '46' -Extra @('-DefaultNtrims', '50')
    Expect-Row 'noisy' 48 '| 14.000 | 14.000 13.000 14.000 | +2.56% |'
    Expect-Row 'noisy' 48 '| no gain |'

    # The default comes from TARI_ARCH_FLAGS / build_flags, like the recall
    # test, and is added to the list when missing.
    $env:TARI_ARCH_FLAGS = '-DTARI_C29_DEFAULT_NTRIMS=48'
    $null = Expect-Choice -Name 'default48' -Scenario 'edges' -Chosen '42' -Extra @('-Ntrims', '50,46,44,42,40')
    Remove-Item Env:TARI_ARCH_FLAGS
    Expect-Row 'default48' 48 '| default |'
    Expect-Row 'default48' 50 '| -0.30% |'

    Expect-Failure 'old' 'old' 'is the solver built with the ntrims statistics?' @('-DefaultNtrims', '50')
    Expect-Failure 'crash' 'crash' 'solver run failed' @('-DefaultNtrims', '50')
    Expect-Failure 'loaddies' 'loaddies' '2-core load solver exited early' @('-DefaultNtrims', '50')
    Expect-Failure 'stopabove' 'edges' 'was not measured' @('-DefaultNtrims', '36', '-Ntrims', '40,36')
    Expect-Failure 'odd' 'edges' 'ntrims must be even' @('-Ntrims', '50,47')
    Expect-Failure 'noarch' 'edges' '-Arch must be' -Arch 'sm_75'
    Expect-Failure 'badcount' 'edges' 'not a whole number' @('-Count', '2k')
    Expect-Failure 'nosolver' 'edges' 'solver not found' @('-Solver', (Join-Path $tempRoot 'missing.exe')) -NoDryRun
} finally {
    Remove-Item Env:TARI_FAKE_SOLVER_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:TARI_FAKE_SOLVER_STATE -ErrorAction SilentlyContinue
    Remove-Item Env:TARI_ARCH_FLAGS -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -ne 0) {
    [Console]::Error.WriteLine("$($script:failures) of $($script:checks) ntrims sweep checks failed")
    exit 1
}
Write-Host "PASS: $($script:checks) ntrims sweep checks"

# Trim-round count (ntrims) sweep for one GPU arch (spec 3 part B).
# Guide: docs/ntrims_sweep.md. tools/ntrims_sweep.sh is the Linux version of
# the same sweep; tests/ntrims_sweep_test.ps1 runs this with a fake solver.
#
# Runs the release solver at each ntrims (auto pipeline) and picks the lowest
# ntrims within the limits that beats the current default by >= 0.5%.
#
#   powershell -ExecutionPolicy Bypass -File tools\ntrims_sweep.ps1 -Arch sm_89
#
# -Solver PATH        solver (default: bin\tari_c29_solver_<arch>.exe)
# -Out DIR            results directory (default: ntrims-sweep\<arch>-<time>)
# -Ntrims LIST        even ntrims values, comma separated (default: 50,48,46,44,42,40,36,32);
#                     the current default is always added
# -Count N            graphs per run (default: 2000)
# -Runs N             measured runs per ntrims (default: 3)
# -WarmupSeconds N    warm-up before each ntrims (default: 60; 0 with -DryRun)
# -Device N           GPU for the measured runs (default: 0)
# -LoadDevice N       GPU for the second process in the 2-core check (default: -Device)
# -LoadPipeline N     --pipeline of that second process (default: 1)
# -AffinityMask N     cores for the 2-core check, as a bit mask (default: 3 = cores 0 and 1)
# -DefaultNtrims N    current default (default: read from build_flags\<arch>.flags or
#                     TARI_ARCH_FLAGS, like tests\tari_c29_gpu_recall.py)
# -Python CMD         Python used for the default and the dry run (default: python)
# -DryRun             use tests\ntrims_sweep_fake_solver.py instead of the GPU
param(
    [string]$Arch = '',
    [string]$Solver = '',
    [string]$Out = '',
    [string]$Ntrims = '50,48,46,44,42,40,36,32',
    [string]$Count = '2000',
    [string]$Runs = '3',
    [string]$WarmupSeconds = '',
    [string]$Device = '0',
    [string]$LoadDevice = '',
    [string]$LoadPipeline = '1',
    [string]$AffinityMask = '3',
    [string]$DefaultNtrims = '',
    [string]$Python = 'python',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$inv = [Globalization.CultureInfo]::InvariantCulture

$EdgeLimit = 524288      # 50% of MAXEDGES (2^20)
$BusyLimit = 0.40        # main-thread busy fraction in the 2-core check
$BusyLimitText = '0.40'
$MinGain = 0.005         # a gain needs +0.5% on the median and every run above the baseline
$LongCount = '1000000000' # --count for warm-up and load processes, which are stopped

$script:background = $null

function Stop-Background {
    if ($null -ne $script:background) {
        if (-not $script:background.HasExited) {
            Stop-Process -Id $script:background.Id -Force -ErrorAction SilentlyContinue
        }
        $script:background.WaitForExit()
        $script:background = $null
    }
}

function Fail {
    param([string]$Message)
    Stop-Background
    [Console]::Error.WriteLine("ntrims_sweep: $Message")
    exit 1
}

function Test-Uint {
    param([string]$Value)
    return $Value -match '^(0|[1-9][0-9]*)$'
}

function ConvertTo-Number {
    param([string]$Value)
    return [double]::Parse($Value, $inv)
}

if (@('sm_86', 'sm_89', 'sm_120') -notcontains $Arch) {
    Fail '-Arch must be sm_86, sm_89 or sm_120'
}
if ($WarmupSeconds -eq '') {
    if ($DryRun) { $WarmupSeconds = '0' } else { $WarmupSeconds = '60' }
}
if ($LoadDevice -eq '') { $LoadDevice = $Device }
foreach ($value in @($Count, $Runs, $WarmupSeconds, $Device, $LoadDevice, $LoadPipeline, $AffinityMask)) {
    if (-not (Test-Uint $value)) { Fail "not a whole number: $value" }
}
if ([long]$Count -lt 1 -or [int]$Runs -lt 1 -or [int]$LoadPipeline -lt 1 -or [long]$AffinityMask -lt 1) {
    Fail '-Count, -Runs, -LoadPipeline and -AffinityMask must be >= 1'
}

if ($DryRun) {
    $solverExe = $Python
    $solverPrefix = @(Join-Path (Join-Path $root 'tests') 'ntrims_sweep_fake_solver.py')
    $solverLabel = 'fake solver (dry run)'
} else {
    if ($Solver -eq '') { $Solver = Join-Path (Join-Path $root 'bin') "tari_c29_solver_$Arch.exe" }
    if (-not (Test-Path -LiteralPath $Solver -PathType Leaf)) {
        Fail "solver not found: $Solver (build it with build_solver.bat $Arch)"
    }
    $solverExe = (Resolve-Path -LiteralPath $Solver).Path
    $solverPrefix = @()
    $solverLabel = $Solver
}

if ($DefaultNtrims -eq '') {
    $code = 'import sys; sys.path.insert(0, sys.argv[1]); import tari_c29_gpu_recall as r; print(r.release_compiled_ntrims(sys.argv[2]))'
    try {
        $DefaultNtrims = (& $Python -c $code (Join-Path $root 'tests') $Arch | Out-String).Trim()
    } catch {
        Fail "could not run $Python to read the default ntrims: $_"
    }
    if ($LASTEXITCODE -ne 0) { Fail "could not read the default ntrims with $Python" }
}
if (-not (Test-Uint $DefaultNtrims)) { Fail "bad default ntrims: $DefaultNtrims" }

# Even values, highest first, with the default included once.
$requested = @($Ntrims -split '[,\s]+' | Where-Object { $_ -ne '' }) + @($DefaultNtrims)
foreach ($n in $requested) {
    if (-not (Test-Uint $n) -or [int]$n -lt 2 -or ([int]$n % 2) -ne 0) {
        Fail "ntrims must be even and >= 2: $n"
    }
}
$ntrimsValues = @($requested | ForEach-Object { [int]$_ } | Sort-Object -Descending -Unique)

if ($Out -eq '') {
    $Out = Join-Path (Join-Path $root 'ntrims-sweep') ($Arch + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path  # .NET file calls need a full path
$csv = Join-Path $Out 'sweep.csv'
$table = Join-Path $Out 'sweep.md'

function Format-Argument {
    param([string]$Value)
    if ($Value -match '[\s"]' -or $Value -eq '') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

# Starts a solver with stdout and stderr in LogBase.out.txt / .err.txt and,
# if Affinity is non-zero, pins it to those cores.
function Start-Solver {
    param([string[]]$Arguments, [string]$LogBase, [long]$Affinity = 0)
    $line = (@($solverPrefix) + $Arguments | ForEach-Object { Format-Argument $_ }) -join ' '
    $p = Start-Process -FilePath $solverExe -ArgumentList $line -NoNewWindow -PassThru `
        -RedirectStandardOutput "$LogBase.out.txt" -RedirectStandardError "$LogBase.err.txt"
    $null = $p.Handle  # keeps ExitCode readable after the process ends
    if ($Affinity -ne 0) {
        try {
            $p.ProcessorAffinity = [IntPtr]$Affinity
        } catch {
            if (-not $p.HasExited) { throw }
        }
    }
    return $p
}

# Joins the two output files into LogBase.log.
function Join-Log {
    param([string]$LogBase)
    $text = [IO.File]::ReadAllText("$LogBase.out.txt") + [IO.File]::ReadAllText("$LogBase.err.txt")
    [IO.File]::WriteAllText("$LogBase.log", $text)
    Remove-Item -LiteralPath "$LogBase.out.txt", "$LogBase.err.txt"
    return "$LogBase.log"
}

function Start-Long {
    param([string[]]$Arguments, [string]$LogBase, [long]$Affinity = 0)
    $script:background = Start-Solver -Arguments (@('--count', $LongCount) + $Arguments) -LogBase $LogBase -Affinity $Affinity
}

function Stop-Long {
    param([string]$What, [string]$LogBase)
    $p = $script:background
    $exited = $p.HasExited
    Stop-Background
    $log = Join-Log $LogBase
    if ($exited) { Fail "$What exited early; see $log" }
}

function Invoke-Measured {
    param([string[]]$Arguments, [string]$LogBase, [long]$Affinity = 0)
    $p = Start-Solver -Arguments (@('--count', $Count) + $Arguments) -LogBase $LogBase -Affinity $Affinity
    $p.WaitForExit()
    $log = Join-Log $LogBase
    if ($p.ExitCode -ne 0) { Fail "solver run failed; see $log" }
    return $log
}

# Reads the summary block of one solver log.
function Read-Summary {
    param([string]$Log)
    $text = [IO.File]::ReadAllText($Log)
    $patterns = @(
        '(?m)^graphs solved\s*:.*=>\s*([0-9.]+) graphs/s',
        '(?m)^surviving edges:\s*min=([0-9]+) p50=([0-9]+) p99=([0-9]+) max=([0-9]+)',
        '(?m)^findcycles ms\s*:\s*p50=([0-9.]+) p99=([0-9.]+) max=([0-9.]+)',
        '(?m)^cpu busy\s*:\s*fraction=([0-9.]+)',
        '(?m)^lost edges\s*:\s*oops_graphs=([0-9]+) node_overflow_graphs=([0-9]+)'
    )
    $values = @()
    foreach ($pattern in $patterns) {
        $m = [regex]::Match($text, $pattern)
        if (-not $m.Success) {
            Fail "cannot read the summary in $Log (is the solver built with the ntrims statistics?)"
        }
        for ($g = 1; $g -lt $m.Groups.Count; $g++) { $values += $m.Groups[$g].Value }
    }
    return [pscustomobject]@{
        Gps = $values[0]; EdgesMin = $values[1]; EdgesP50 = $values[2]; EdgesP99 = $values[3]
        EdgesMax = $values[4]; MsP50 = $values[5]; MsP99 = $values[6]; MsMax = $values[7]
        Busy = $values[8]; Oops = $values[9]; Overflow = $values[10]
    }
}

function Get-MaxText {
    param([string[]]$Values)
    return ($Values | Sort-Object { ConvertTo-Number $_ } | Select-Object -Last 1)
}

function Get-Median {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    if ($n % 2) { return $sorted[($n - 1) / 2] }
    return ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2
}

# System details for the PR.
$gpuName = 'unknown'
$driver = 'unknown'
$cuda = 'unknown'
if (-not $DryRun -and (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    $driver = (& nvidia-smi --query-gpu=driver_version --format=csv,noheader -i $Device 2>$null | Select-Object -First 1)
    $m = [regex]::Match((& nvidia-smi 2>$null | Out-String), 'CUDA Version:\s*([0-9.]+)')
    if ($m.Success) { $cuda = $m.Groups[1].Value }
    if (-not $driver) { $driver = 'unknown' }
}
if (-not $DryRun -and (Get-Command nvcc -ErrorAction SilentlyContinue)) {
    $m = [regex]::Match((& nvcc --version | Out-String), 'release ([0-9.]+)')
    if ($m.Success) { $cuda = "$cuda (nvcc $($m.Groups[1].Value))" }
}

$csvLines = New-Object System.Collections.Generic.List[string]
$csvLines.Add('arch,ntrims,kind,run,graphs_per_sec,edges_min,edges_p50,edges_p99,edges_max,findcycles_ms_p50,findcycles_ms_p99,findcycles_ms_max,busy_fraction,oops_graphs,node_overflow_graphs,log')

function Add-CsvRow {
    param([int]$N, [string]$Kind, [int]$Run, $S, [string]$Log)
    $csvLines.Add((@($Arch, $N, $Kind, $Run, $S.Gps, $S.EdgesMin, $S.EdgesP50, $S.EdgesP99, $S.EdgesMax,
        $S.MsP50, $S.MsP99, $S.MsMax, $S.Busy, $S.Oops, $S.Overflow, (Split-Path -Leaf $Log)) -join ','))
}

$results = @()
$stopped = $false
try {
    foreach ($n in $ntrimsValues) {
        $result = [pscustomobject]@{
            Ntrims = $n; Measured = $false; GpsRuns = @(); Median = 0.0; EdgesP99 = ''; EdgesMax = ''
            MsP99Full = ''; MsP99Weak = ''; BusyFull = ''; BusyWeak = ''; Stop = ''; Gain = $false
        }
        $results += $result
        if ($stopped) { continue }
        Write-Host "=== ntrims $n ==="
        $ntrimsArgs = @('--device', $Device, '--ntrims', "$n")

        if ([int]$WarmupSeconds -gt 0) {
            Write-Host "warm-up $WarmupSeconds s"
            $base = Join-Path $Out "ntrims-$n-warmup"
            Start-Long -Arguments $ntrimsArgs -LogBase $base
            Start-Sleep -Seconds ([int]$WarmupSeconds)
            Stop-Long -What 'warm-up solver' -LogBase $base
        }

        $p99s = @(); $maxes = @(); $ms99s = @(); $busys = @(); $lost = 0
        for ($r = 1; $r -le [int]$Runs; $r++) {
            $log = Invoke-Measured -Arguments $ntrimsArgs -LogBase (Join-Path $Out "ntrims-$n-run$r")
            $s = Read-Summary $log
            Add-CsvRow -N $n -Kind 'full' -Run $r -S $s -Log $log
            Write-Host "run ${r}: $($s.Gps) g/s, edges max $($s.EdgesMax), findcycles p99 $($s.MsP99) ms, busy $($s.Busy)"
            $result.GpsRuns += $s.Gps
            $p99s += $s.EdgesP99; $maxes += $s.EdgesMax; $ms99s += $s.MsP99; $busys += $s.Busy
            $lost += [long]$s.Oops + [long]$s.Overflow
        }

        # 2-core check: a second solver on the same cores, then one measured run.
        $loadBase = Join-Path $Out "ntrims-$n-2core-load"
        Start-Long -Arguments @('--device', $LoadDevice, '--pipeline', $LoadPipeline, '--ntrims', "$n") `
            -LogBase $loadBase -Affinity ([long]$AffinityMask)
        if (-not $DryRun) {
            Start-Sleep -Seconds 10  # let the second process allocate its GPU memory first
        }
        $log = Invoke-Measured -Arguments $ntrimsArgs -LogBase (Join-Path $Out "ntrims-$n-2core") `
            -Affinity ([long]$AffinityMask)
        Stop-Long -What '2-core load solver' -LogBase $loadBase
        $s = Read-Summary $log
        Add-CsvRow -N $n -Kind '2core' -Run 1 -S $s -Log $log
        Write-Host "2-core: $($s.Gps) g/s, findcycles p99 $($s.MsP99) ms, busy $($s.Busy)"
        $p99s += $s.EdgesP99; $maxes += $s.EdgesMax
        $lost += [long]$s.Oops + [long]$s.Overflow

        $result.Measured = $true
        $result.Median = Get-Median ($result.GpsRuns | ForEach-Object { ConvertTo-Number $_ })
        $result.EdgesP99 = Get-MaxText $p99s
        $result.EdgesMax = Get-MaxText $maxes
        $result.MsP99Full = Get-MaxText $ms99s
        $result.MsP99Weak = $s.MsP99
        $result.BusyFull = Get-MaxText $busys
        $result.BusyWeak = $s.Busy

        $reasons = @()
        if ([long]$result.EdgesMax -gt $EdgeLimit) { $reasons += "max edges $($result.EdgesMax) > $EdgeLimit" }
        if ($lost -gt 0) { $reasons += 'OOPS or NODE OVERFLOW' }
        if ((ConvertTo-Number $s.Busy) -gt $BusyLimit) { $reasons += "2-core busy $($s.Busy) > $BusyLimitText" }
        if ($reasons.Count -gt 0) {
            $result.Stop = $reasons -join '; '
            Write-Host "stop: $($result.Stop)"
            $stopped = $true
        }
    }
} finally {
    Stop-Background
}
[IO.File]::WriteAllLines($csv, $csvLines)

$m = [regex]::Match([IO.File]::ReadAllText((Join-Path $Out "ntrims-$($ntrimsValues[0])-run1.log")),
    '(?m)^TARI\.Miner C29 solver .* on (.*) \([0-9]+ GB, sm_[0-9]+\)\s*$')
if ($m.Success) { $gpuName = $m.Groups[1].Value }

# Baseline and choice.
$base = $results | Where-Object { $_.Measured -and $_.Ntrims -eq [int]$DefaultNtrims } | Select-Object -First 1
$chosen = $null
if ($null -ne $base) {
    foreach ($r in $results) {
        if (-not $r.Measured -or $r.Stop -ne '' -or $r.Ntrims -eq $base.Ntrims) { continue }
        $ok = $r.Median -ge $base.Median * (1 + $MinGain)
        foreach ($g in $r.GpsRuns) {
            if (-not ((ConvertTo-Number $g) -gt $base.Median)) { $ok = $false }
        }
        if ($ok) {
            $r.Gain = $true
            $chosen = $r  # values are highest first, so the last gain is the lowest
        }
    }
}

$md = New-Object System.Collections.Generic.List[string]
$md.Add("## ntrims sweep: $Arch")
$md.Add('')
$md.Add("- GPU: $gpuName, driver $driver, CUDA $cuda")
$md.Add("- solver: $solverLabel, --count $Count, $Runs runs per ntrims (median), auto pipeline, $WarmupSeconds s warm-up")
$md.Add("- 2-core check: affinity mask $AffinityMask, second solver on device $LoadDevice with --pipeline $LoadPipeline")
$md.Add("- limits: max edges <= $EdgeLimit, no OOPS / NODE OVERFLOW, 2-core busy <= $BusyLimitText; gain >= 0.5% and every run above the default's median")
$md.Add("- current default: $DefaultNtrims")
$md.Add('')
$md.Add('| arch | ntrims | g/s median | g/s runs | vs default | edges p99 | edges max | findcycles ms p99 (full / 2-core) | busy (full / 2-core) | result |')
$md.Add('|---|---|---|---|---|---|---|---|---|---|')
foreach ($r in $results) {
    if (-not $r.Measured) {
        $md.Add("| $Arch | $($r.Ntrims) | | | | | | | | not run (stopped above) |")
        continue
    }
    $vs = ''
    if ($null -ne $base) {
        $vs = ((($r.Median / $base.Median) - 1) * 100).ToString('+0.00;-0.00', $inv) + '%'
    }
    if ($r.Stop -ne '') { $res = "stop: $($r.Stop)" }
    elseif ($r.Ntrims -eq $base.Ntrims) { $res = 'default' }
    elseif ($null -ne $chosen -and $r.Ntrims -eq $chosen.Ntrims) { $res = '**chosen**' }
    elseif ($r.Gain) { $res = 'gain' }
    else { $res = 'no gain' }
    $busyCell = [string]::Format($inv, '{0:F1}% / {1:F1}%',
        (ConvertTo-Number $r.BusyFull) * 100, (ConvertTo-Number $r.BusyWeak) * 100)
    $md.Add("| $Arch | $($r.Ntrims) | $($r.Median.ToString('F3', $inv)) | $($r.GpsRuns -join ' ') | $vs | $($r.EdgesP99) | $($r.EdgesMax) | $($r.MsP99Full) / $($r.MsP99Weak) | $busyCell | $res |")
}
[IO.File]::WriteAllLines($table, $md)

Write-Host ''
$md | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host "raw logs and sweep.csv: $Out"
if ($null -eq $base) {
    Fail "the current default ntrims $DefaultNtrims was not measured (a stop rule fired above it)"
}
if ($base.Stop -ne '') {
    [Console]::Error.WriteLine("warning: the current default ntrims $DefaultNtrims is already over a limit: $($base.Stop)")
}
if ($null -eq $chosen) {
    Write-Host 'chosen_ntrims=none'
    Write-Host "No ntrims within the limits beats the default $DefaultNtrims by 0.5% or more; keep it."
    exit 0
}
$pick = $chosen.Ntrims
Write-Host "chosen_ntrims=$pick"
Write-Host @"

Next steps (docs/ntrims_sweep.md):
1. Recall comparison with the current binary at --ntrims $pick (reference stays at 50):
   $Python tests\tari_c29_gpu_recall.py run --candidate bin\tari_c29_solver_$Arch.exe --reference bin\validation\tari_c29_solver_${Arch}_reference.exe --arch $Arch --output-dir validation --parity-pipeline 2 --candidate-ntrims $pick
2. Ship: in build_flags\$Arch.flags set the line
   -DTARI_C29_DEFAULT_NTRIMS=$pick
   (replace any existing -DTARI_C29_DEFAULT_NTRIMS= line), rebuild with build_solver.bat $Arch,
   and run the recall comparison again without --candidate-ntrims.
"@
exit 0

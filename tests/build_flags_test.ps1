$ErrorActionPreference = 'Stop'
# Regression checks for build_flags\read_arch_flags.bat, the reader behind
# build_solver.bat and build_pool_miner.bat. tests/build_flags_test.sh runs the
# same reader cases against the shell reader.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$helper = Join-Path $root 'build_flags\read_arch_flags.bat'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'tari-c29-build-flags-test-' + [Guid]::NewGuid().ToString('N')
)
$checks = 0

# Same rules as the readers: text from '#' is a comment, every remaining
# whitespace-separated word is one flag.
function Get-ExpectedFlags {
    param([string]$Path)
    $words = @()
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $words += ($line -split '#', 2)[0].Split(
            [char[]]" `t`r", [StringSplitOptions]::RemoveEmptyEntries
        )
    }
    return ($words -join ' ')
}

function Read-Flags {
    param([string]$FlagsRoot, [string]$Arch)
    $env:T_ROOT = $FlagsRoot
    $env:T_ARCH = $Arch
    $env:T_HELPER = $helper
    $output = & cmd.exe /d /c (Join-Path $tempRoot 'driver.cmd') 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Reader driver failed with exit $LASTEXITCODE.`n$($output -join "`n")"
    }
    $line = @($output | Where-Object { "$_".StartsWith('FLAGS[') })
    if ($line.Count -ne 1) {
        throw "Reader driver printed no FLAGS line.`n$($output -join "`n")"
    }
    return "$($line[0])".Substring(6).TrimEnd(']')
}

function Assert-Flags {
    param([string]$Label, [string]$FlagsRoot, [string]$Arch, [string]$Expected)
    $script:checks++
    $actual = Read-Flags $FlagsRoot $Arch
    if ($actual -cne $Expected) {
        throw "${Label}: expected [$Expected], got [$actual]"
    }
}

function Assert-Contains {
    param([string]$Label, [string]$Text, [string]$Needle)
    $script:checks++
    if (-not $Text.Contains($Needle)) {
        throw "${Label}: output lacks [$Needle].`n$Text"
    }
}

function Invoke-Build {
    param([string]$Script, [string[]]$Arguments)
    $output = & cmd.exe /d /c (Join-Path $root $Script) @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Script $Arguments failed with exit $LASTEXITCODE.`n$($output -join "`n")"
    }
    return ($output -join "`n")
}

$savedOverride = $env:TARI_ARCH_FLAGS
$savedNvcc = $env:NVCC
try {
    Remove-Item Env:TARI_ARCH_FLAGS -ErrorAction SilentlyContinue
    $fixtures = Join-Path $tempRoot 'fixtures'
    New-Item -ItemType Directory -Path (Join-Path $fixtures 'build_flags') -Force |
        Out-Null
    [IO.File]::WriteAllText((Join-Path $tempRoot 'driver.cmd'), (
        "@echo off`r`n" +
        "setlocal`r`n" +
        "set `"ROOT=%T_ROOT%\`"`r`n" +
        "set `"ARCH=%T_ARCH%`"`r`n" +
        "call `"%T_HELPER%`"`r`n" +
        "echo FLAGS[%EXTRA_FLAGS%]`r`n"
    ))
    $body = "# header||  -DQ=1   # inline|#-DZ=2|   `t|`t-DR=3 `t|  # -DY=4|-DS=5"
    [IO.File]::WriteAllText(
        (Join-Path $fixtures 'build_flags\sm_crlf.flags'),
        $body.Replace('|', "`r`n")
    )
    [IO.File]::WriteAllText(
        (Join-Path $fixtures 'build_flags\sm_lf.flags'),
        $body.Replace('|', "`n") + "`n"
    )
    [IO.File]::WriteAllText((Join-Path $fixtures 'build_flags\sm_empty.flags'), '')

    Assert-Flags 'CRLF file' $fixtures 'sm_crlf' '-DQ=1 -DR=3 -DS=5'
    Assert-Flags 'LF file' $fixtures 'sm_lf' '-DQ=1 -DR=3 -DS=5'
    Assert-Flags 'empty file' $fixtures 'sm_empty' ''
    Assert-Flags 'missing file' $fixtures 'sm_missing' ''

    foreach ($file in Get-ChildItem (Join-Path $root 'build_flags') -Filter '*.flags') {
        Assert-Flags "committed $($file.BaseName)" $root $file.BaseName (
            Get-ExpectedFlags $file.FullName
        )
    }

    $env:TARI_ARCH_FLAGS = "  -DA=1`t-DB=2  "
    Assert-Flags 'TARI_ARCH_FLAGS replaces the file' $fixtures 'sm_crlf' '-DA=1 -DB=2'
    Assert-Flags 'TARI_ARCH_FLAGS without a file' $fixtures 'sm_missing' '-DA=1 -DB=2'
    $env:TARI_ARCH_FLAGS = ' '
    Assert-Flags 'blank TARI_ARCH_FLAGS means no flags' $fixtures 'sm_crlf' ''
    Remove-Item Env:TARI_ARCH_FLAGS

    # End to end through the real build scripts with a stand-in nvcc that only
    # echoes its arguments.
    $env:NVCC = Join-Path $tempRoot 'nvcc.cmd'
    [IO.File]::WriteAllText($env:NVCC, "@echo NVCC %*`r`n")
    $sm120 = Get-ExpectedFlags (Join-Path $root 'build_flags\sm_120.flags')
    $flagLine = "Arch flags for sm_120 [build_flags\sm_120.flags]: $sm120"
    foreach ($buildScript in @('build_solver.bat', 'build_pool_miner.bat')) {
        $output = Invoke-Build $buildScript @('sm_120')
        Assert-Contains "$buildScript prints sm_120 flags" $output $flagLine
        Assert-Contains "$buildScript passes sm_120 flags" $output " $sm120 -maxrregcount=96"
    }
    $output = Invoke-Build 'build_solver.bat' @('sm_86')
    Assert-Contains 'sm_86 prints no flags' $output 'Arch flags for sm_86 [build_flags\sm_86.flags]: (none)'
    $output = Invoke-Build 'build_solver.bat' @('sm_120', 'reference')
    $script:checks++
    if ($output.Contains('Arch flags') -or $output.Contains('-DROUND23_TPB=960')) {
        throw "Reference build picked up release arch flags.`n$output"
    }

    Write-Host "PASS: $checks build flag reader checks"
}
finally {
    $env:NVCC = $savedNvcc
    if ($null -ne $savedOverride) {
        $env:TARI_ARCH_FLAGS = $savedOverride
    }
    else {
        Remove-Item Env:TARI_ARCH_FLAGS -ErrorAction SilentlyContinue
    }
    Remove-Item Env:T_ROOT, Env:T_ARCH, Env:T_HELPER -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

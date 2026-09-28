@echo off
REM Build the standalone Tari C29 GPU solver/benchmark with nvcc.
REM Default arch sm_120 (RTX 5090 Blackwell). Override: build_solver.bat sm_89  (Ada 4070TiS/4090)
setlocal
set "ROOT=%~dp0"
set ARCH=%1
if "%ARCH%"=="" set ARCH=sm_120
set BUILD_ARCH=%ARCH:sm_=%
set PROFILE=%2
if "%PROFILE%"=="" set PROFILE=release
if not exist "%ROOT%bin" mkdir "%ROOT%bin"
if /I "%PROFILE%"=="release" goto release_profile
if /I "%PROFILE%"=="reference" goto reference_profile
echo Unknown solver profile "%PROFILE%". Use release or reference.
endlocal
exit /b 2

:release_profile
set "OUTPUT=%ROOT%bin\tari_c29_solver_%ARCH%.exe"
set "PROFILE_FLAGS=-DGRAPH_UNION_SKIP=1 -DRECOVERY_SMALL_OUTPUT=1 -DSEEDA_REHASH=1"
call "%ROOT%build_flags\read_arch_flags.bat"
goto profile_ready

:reference_profile
if not exist "%ROOT%bin\validation" mkdir "%ROOT%bin\validation"
set "OUTPUT=%ROOT%bin\validation\tari_c29_solver_%ARCH%_reference.exe"
set "PROFILE_FLAGS=-DTARI_C29_REFERENCE_BUILD=1 -DGRAPH_UNION_SKIP=0 -DRECOVERY_SMALL_OUTPUT=0 -DSEEDA_REHASH=0 -DSKIP_LATE_NULL_CHECKS=0 -DWARP_DST_ATOMICS_LATE=0 -DTARI_C29_DEFAULT_NTRIMS=50 -DSEEDB_REVERSE_LOOP=0 -DROUND0_DST_HASH_DYNAMIC_BITS=0 -DROUND0_DST_HASH_DYNAMIC_PROBES=8 -DROUND0_DST_HASH_FALLBACK_PLAIN=0 -DROUND0_DST_HASH_REPLAY_NORMAL_LOAD=0 -DROUND0_DST_HASH_REVERSE_INSERT=0 -DFUSE_FINAL_TAIL_CURRENT=0 -DFUSE_FINAL_TAIL_COUNT_NORMAL_LOAD=0 -DROUND1_COUNT_NORMAL_LOAD=0 -DROUND23_COUNT_NORMAL_LOAD=0 -DROUND23_TPB=1024"
set EXTRA_FLAGS=

:profile_ready

if not defined NVCC set "NVCC=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2\bin\nvcc.exe"
if not exist "%NVCC%" set "NVCC=nvcc"
set "CUCKAROO=%ROOT%third_party\cuckoo\src\cuckaroo"
set "CRYPTO=%ROOT%third_party\cuckoo\src\crypto"

echo Building tari_c29_solver for %ARCH% profile=%PROFILE% ...
if /I "%PROFILE%"=="release" call "%ROOT%build_flags\read_arch_flags.bat" print
"%NVCC%" -O3 -std=c++17 -arch=%ARCH% --default-stream per-thread -DXBITS=7 -DIDXSHIFT=9 -DTARI_C29_BUILD_ARCH=%BUILD_ARCH% %PROFILE_FLAGS% %EXTRA_FLAGS% -maxrregcount=96 -Xptxas -flcm=cg ^
    -I"%ROOT%compat" ^
    -I"%CUCKAROO%" ^
    -I"%CRYPTO%" ^
    -Xcompiler "/wd4244 /wd4267 /wd4334 /wd4018" ^
    "%ROOT%tari_c29_solver.cu" ^
    "%ROOT%tari_c29.cpp" ^
    "%CRYPTO%\blake2b-ref.c" ^
    -o "%OUTPUT%"

if errorlevel 1 (
    echo BUILD FAILED
    endlocal
    exit /b 1
) else (
    echo.
    echo BUILD OK -^> %OUTPUT%
    echo Try: "%OUTPUT%" --count 200
)
endlocal

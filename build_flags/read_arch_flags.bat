@echo off
REM Called by build_solver.bat and build_pool_miner.bat; not meant to be run.
REM Uses the caller's ROOT (with trailing backslash) and ARCH, and has no
REM setlocal of its own so the variables it sets reach the caller.
REM
REM   call read_arch_flags.bat         sets EXTRA_FLAGS and ARCH_FLAGS_SOURCE
REM   call read_arch_flags.bat print   prints the effective list
REM
REM TARI_ARCH_FLAGS, when non-empty, replaces the file verbatim. A value of
REM only spaces means "no extra flags" (set "TARI_ARCH_FLAGS= ").
REM Otherwise %ROOT%build_flags\%ARCH%.flags is read: text from '#' to end of
REM line is a comment, blank lines are skipped, and each whitespace-separated
REM word is one flag. LF or CRLF line endings both work. A missing file means
REM no extra flags.
if /I "%~1"=="print" goto print_flags

set "EXTRA_FLAGS="
set "ARCH_FLAG_WORD="
set "ARCH_FLAG_REST="
if defined TARI_ARCH_FLAGS goto from_env
set "ARCH_FLAGS_FILE=%ROOT%build_flags\%ARCH%.flags"
if exist "%ARCH_FLAGS_FILE%" goto from_file
set "ARCH_FLAGS_SOURCE=none, no build_flags\%ARCH%.flags"
goto :eof

:from_env
set "ARCH_FLAGS_SOURCE=TARI_ARCH_FLAGS"
call :append_words "%TARI_ARCH_FLAGS%"
goto :eof

:from_file
set "ARCH_FLAGS_SOURCE=build_flags\%ARCH%.flags"
REM eol=# drops lines starting with '#'; delims=# keeps only the text before
REM an inline '#'. for /f already skips empty lines and strips CR from CRLF.
for /f "usebackq eol=# tokens=1 delims=#" %%L in ("%ARCH_FLAGS_FILE%") do call :append_words "%%L"
goto :eof

:append_words
REM Append every whitespace-separated word of %1 to EXTRA_FLAGS. for /f with
REM its default delimiters (space, tab) also trims leading/trailing blanks.
set "ARCH_FLAG_REST=%~1"
:append_words_loop
if not defined ARCH_FLAG_REST goto :eof
set "ARCH_FLAG_WORD="
set "ARCH_FLAG_NEXT="
for /f "tokens=1*" %%A in ("%ARCH_FLAG_REST%") do (
    set "ARCH_FLAG_WORD=%%A"
    set "ARCH_FLAG_NEXT=%%B"
)
set "ARCH_FLAG_REST=%ARCH_FLAG_NEXT%"
if not defined ARCH_FLAG_WORD goto :eof
if defined EXTRA_FLAGS set "EXTRA_FLAGS=%EXTRA_FLAGS% %ARCH_FLAG_WORD%"
if not defined EXTRA_FLAGS set "EXTRA_FLAGS=%ARCH_FLAG_WORD%"
goto append_words_loop

:print_flags
if defined EXTRA_FLAGS echo Arch flags for %ARCH% [%ARCH_FLAGS_SOURCE%]: %EXTRA_FLAGS%
if not defined EXTRA_FLAGS echo Arch flags for %ARCH% [%ARCH_FLAGS_SOURCE%]: (none)
goto :eof

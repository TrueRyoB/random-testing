<#!
.SYNOPSIS
Compiles an input generator and two C++ programs, then stress-tests them.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)] [string] $Generator,
    [Parameter(Mandatory, Position = 1)] [string] $ProgramA,
    [Parameter(Mandatory, Position = 2)] [string] $ProgramB,
    [Parameter(Position = 3, HelpMessage = 'Optional C++ evaluator. It receives Program A and Program B output-file paths as argv[1] and argv[2], and must exit 0 to accept.')]
    [string] $Evaluator,
    [ValidateRange(0, [int]::MaxValue)] [int] $Iterations = 0,
    [ValidateRange(0.001, [double]::MaxValue)] [double] $TimeoutSeconds = 3,
    [Parameter(HelpMessage = 'Compiler command or full path to g++.exe, for example C:\\tools\\mingw64\\bin\\g++.exe')]
    [string] $Compiler = 'g++',
    [string] $BuildDir = '.stress-build',
    [string] $FailureRoot = 'stress-failure'
)

$ErrorActionPreference = 'Stop'

function Get-SourcePath([string] $PathText) {
    $path = (Resolve-Path -LiteralPath $PathText).Path
    if ([IO.Path]::GetExtension($path).ToLowerInvariant() -notin '.cpp', '.cc', '.cxx') {
        throw "Expected a C++ source file: $path"
    }
    return $path
}

function Compile-Source([string] $Source, [string] $Name) {
    $extension = if ($IsWindows -or $env:OS -eq 'Windows_NT') { '.exe' } else { '' }
    $output = Join-Path $script:buildPath ($Name + $extension)
    Write-Host "Compiling $Source"
    & $Compiler '-std=c++17' '-O2' '-pipe' $Source '-o' $output
    if ($LASTEXITCODE -ne 0) {
        throw "Compilation failed for $Source"
    }
    return (Resolve-Path -LiteralPath $output).Path
}

function ConvertTo-ProcessArgument([string] $Argument) {
    # Quote according to the Windows CommandLineToArgvW rules. This also works
    # with the usual argv parsing on Unix and keeps this script compatible
    # with Windows PowerShell 5.1, which lacks ProcessStartInfo.ArgumentList.
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $quoted = [Text.StringBuilder]::new()
    [void] $quoted.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
        }
        elseif ($character -eq '"') {
            [void] $quoted.Append('\', 2 * $backslashes + 1)
            [void] $quoted.Append('"')
            $backslashes = 0
        }
        else {
            if ($backslashes -gt 0) { [void] $quoted.Append('\', $backslashes) }
            [void] $quoted.Append($character)
            $backslashes = 0
        }
    }
    if ($backslashes -gt 0) { [void] $quoted.Append('\', 2 * $backslashes) }
    [void] $quoted.Append('"')
    return $quoted.ToString()
}

function Invoke-Program([string] $FileName, [string] $InputText, [string[]] $Arguments = @()) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($Arguments.Count -gt 0) {
        $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void] $process.Start()
    # Start draining both pipes before waiting.  Otherwise a program with a
    # large output can block while its stdout/stderr pipe is full.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $InputText) {
        $process.StandardInput.Write($InputText)
    }
    $process.StandardInput.Close()

    $completed = $process.WaitForExit([int][Math]::Ceiling($TimeoutSeconds * 1000))
    if (-not $completed) {
        $process.Kill()
        $process.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = if ($completed) { $process.ExitCode } else { $null }
    $process.Dispose()
    return [pscustomobject]@{
        TimedOut = -not $completed
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Get-NormalizedOutput([string] $Text) {
    return (($Text -replace '\s+', ' ').Trim())
}

function Get-OutputLineNumber([string] $Text, [int] $Index) {
    if ($Index -le 0) { return 1 }
    return ([regex]::Matches($Text.Substring(0, $Index), '\r\n|[\r\n]').Count + 1)
}

function Get-OutputLineText([string] $Text, [int] $Index) {
    $lineStart = 0
    $priorBreaks = [regex]::Matches($Text.Substring(0, $Index), '\r\n|[\r\n]')
    if ($priorBreaks.Count -gt 0) {
        $lastBreak = $priorBreaks[$priorBreaks.Count - 1]
        $lineStart = $lastBreak.Index + $lastBreak.Length
    }

    $nextBreak = ([regex]::new('\r\n|[\r\n]')).Match($Text, $Index)
    $lineEnd = if ($nextBreak.Success) { $nextBreak.Index } else { $Text.Length }
    return $Text.Substring($lineStart, $lineEnd - $lineStart)
}

function Get-FirstOutputMismatch([string] $OutputA, [string] $OutputB) {
    # Match non-whitespace tokens so this uses the same comparison semantics as
    # Get-NormalizedOutput, while retaining each token's original line number.
    $tokensA = [regex]::Matches($OutputA, '\S+')
    $tokensB = [regex]::Matches($OutputB, '\S+')
    $limit = [Math]::Max($tokensA.Count, $tokensB.Count)

    for ($index = 0; $index -lt $limit; $index++) {
        $tokenA = if ($index -lt $tokensA.Count) { $tokensA[$index] } else { $null }
        $tokenB = if ($index -lt $tokensB.Count) { $tokensB[$index] } else { $null }
        if ($null -eq $tokenA -or $null -eq $tokenB -or $tokenA.Value -cne $tokenB.Value) {
            return [pscustomobject]@{
                TokenNumber = $index + 1
                ProgramAToken = if ($null -eq $tokenA) { '<missing>' } else { $tokenA.Value }
                ProgramALine = if ($null -eq $tokenA) { '<missing>' } else { Get-OutputLineNumber $OutputA $tokenA.Index }
                ProgramALineText = if ($null -eq $tokenA) { '<missing>' } else { Get-OutputLineText $OutputA $tokenA.Index }
                ProgramBToken = if ($null -eq $tokenB) { '<missing>' } else { $tokenB.Value }
                ProgramBLine = if ($null -eq $tokenB) { '<missing>' } else { Get-OutputLineNumber $OutputB $tokenB.Index }
                ProgramBLineText = if ($null -eq $tokenB) { '<missing>' } else { Get-OutputLineText $OutputB $tokenB.Index }
            }
        }
    }
}

function New-FailureDirectory {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $directory = "${FailureRoot}-${stamp}"
    New-Item -ItemType Directory -Path $directory | Out-Null
    return (Resolve-Path -LiteralPath $directory).Path
}

function Write-Utf8File([string] $Path, [string] $Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Save-Failure([string] $Reason, [string] $InputText, $ResultA, $ResultB) {
    $directory = New-FailureDirectory
    Write-Utf8File (Join-Path $directory 'reason.txt') ($Reason + [Environment]::NewLine)
    if ($null -ne $InputText) { Write-Utf8File (Join-Path $directory 'input.txt') $InputText }
    foreach ($entry in @(@('program_a', $ResultA), @('program_b', $ResultB))) {
        if ($null -eq $entry[1]) { continue }
        Write-Utf8File (Join-Path $directory ($entry[0] + '.stdout.txt')) $entry[1].Stdout
        Write-Utf8File (Join-Path $directory ($entry[0] + '.stderr.txt')) $entry[1].Stderr
        Write-Utf8File (Join-Path $directory ($entry[0] + '.exit_code.txt')) ($entry[1].ExitCode)
    }
    return $directory
}

function Save-EvaluatorResult([string] $Directory, $Result) {
    if ($null -eq $Result) { return }
    Write-Utf8File (Join-Path $Directory 'evaluator.stdout.txt') $Result.Stdout
    Write-Utf8File (Join-Path $Directory 'evaluator.stderr.txt') $Result.Stderr
    Write-Utf8File (Join-Path $Directory 'evaluator.exit_code.txt') ($Result.ExitCode)
}

function Show-FailingInput([string] $InputText) {
    Write-Host "`n--- failing generated input ---"
    Write-Host $InputText
    Write-Host '--- end generated input ---'
}

$compilerCommand = Get-Command $Compiler -ErrorAction SilentlyContinue
if (-not $compilerCommand) {
    throw "Compiler '$Compiler' was not found. Install g++ or use -Compiler <compiler-path>."
}

# g++.exe starts helper programs (cc1plus.exe, collect2.exe) from its own
# installation.  With a full MSYS2/UCRT64 path, that bin directory might not
# be on PATH, so those helpers and the compiled programs cannot load their
# runtime DLLs.  Keep the change local to this script process and its children.
$Compiler = $compilerCommand.Source
$compilerDirectory = Split-Path -Parent $Compiler
if (($IsWindows -or $env:OS -eq 'Windows_NT') -and $compilerDirectory) {
    $pathSeparator = [IO.Path]::PathSeparator
    $pathEntries = $env:Path -split [Regex]::Escape([string] $pathSeparator)
    if ($pathEntries -notcontains $compilerDirectory) {
        $env:Path = $compilerDirectory + $pathSeparator + $env:Path
    }
}

$buildPath = (New-Item -ItemType Directory -Force -Path $BuildDir).FullName
$generatorExe = Compile-Source (Get-SourcePath $Generator) 'generator'
$programAExe = Compile-Source (Get-SourcePath $ProgramA) 'program_a'
$programBExe = Compile-Source (Get-SourcePath $ProgramB) 'program_b'
if ($Evaluator) {
    $evaluatorExe = Compile-Source (Get-SourcePath $Evaluator) 'evaluator'
    $evaluatorOutputAPath = Join-Path $buildPath 'evaluator-program-a-output.txt'
    $evaluatorOutputBPath = Join-Path $buildPath 'evaluator-program-b-output.txt'
}

$test = 0
try {
    while ($Iterations -eq 0 -or $test -lt $Iterations) {
        $test++
        $generated = Invoke-Program $generatorExe $null
        if ($generated.TimedOut -or $generated.ExitCode -ne 0) {
            $reason = if ($generated.TimedOut) { 'Generator timed out' } else { "Generator exited with code $($generated.ExitCode)" }
            $directory = Save-Failure $reason $generated.Stdout $null $null
            Write-Host "FAIL on test ${test}: $reason. Details: $directory" -ForegroundColor Red
            Show-FailingInput $generated.Stdout
            exit 1
        }

        $a = Invoke-Program $programAExe $generated.Stdout
        $b = Invoke-Program $programBExe $generated.Stdout
        if ($a.TimedOut -or $b.TimedOut) {
            $reason = if ($a.TimedOut) { 'Program A timed out' } else { 'Program B timed out' }
            $directory = Save-Failure $reason $generated.Stdout $a $b
            Write-Host "FAIL on test ${test}: $reason. Details: $directory" -ForegroundColor Red
            Show-FailingInput $generated.Stdout
            exit 1
        }
        if ($a.ExitCode -ne 0 -or $b.ExitCode -ne 0) {
            $reason = "Exit codes: A=$($a.ExitCode), B=$($b.ExitCode)"
            $directory = Save-Failure $reason $generated.Stdout $a $b
            Write-Host "FAIL on test ${test}: $reason. Details: $directory" -ForegroundColor Red
            Show-FailingInput $generated.Stdout
            exit 1
        }
        if ($Evaluator) {
            Write-Utf8File $evaluatorOutputAPath $a.Stdout
            Write-Utf8File $evaluatorOutputBPath $b.Stdout
            $evaluation = Invoke-Program $evaluatorExe $null @($evaluatorOutputAPath, $evaluatorOutputBPath)
            if ($evaluation.TimedOut -or $evaluation.ExitCode -ne 0) {
                $reason = if ($evaluation.TimedOut) { 'Evaluator timed out' } else { "Evaluator rejected outputs (exit code $($evaluation.ExitCode))" }
                $directory = Save-Failure $reason $generated.Stdout $a $b
                Save-EvaluatorResult $directory $evaluation
                Write-Host "FAIL on test ${test}: $reason. Details: $directory" -ForegroundColor Red
                if ($evaluation.Stderr) { Write-Host "--- evaluator error output ---`n$($evaluation.Stderr)" -ForegroundColor Red }
                Show-FailingInput $generated.Stdout
                exit 1
            }
        }
        elseif ((Get-NormalizedOutput $a.Stdout) -ne (Get-NormalizedOutput $b.Stdout)) {
            $directory = Save-Failure 'Outputs differ' $generated.Stdout $a $b
            Write-Host "FAIL on test ${test}: outputs differ. Details: $directory" -ForegroundColor Red
            $mismatch = Get-FirstOutputMismatch $a.Stdout $b.Stdout
            Write-Host "First mismatch (token $($mismatch.TokenNumber)):" -ForegroundColor Red
            Write-Host "  program A, line $($mismatch.ProgramALine): $($mismatch.ProgramALineText)" -ForegroundColor Red
            Write-Host "  program B, line $($mismatch.ProgramBLine): $($mismatch.ProgramBLineText)" -ForegroundColor Red
            Write-Host "--- program A output ---`n$($a.Stdout)--- program B output ---`n$($b.Stdout)"
            Show-FailingInput $generated.Stdout
            exit 1
        }
        Write-Host "OK: test $test" -NoNewline
        Write-Host "`r" -NoNewline
    }
}
catch [System.Management.Automation.PipelineStoppedException] {
    Write-Host "`nStopped after $($test - 1) successful test(s)."
    exit 130
}

if ($Evaluator) {
    Write-Host "`nAll $test test(s) accepted by evaluator."
}
else {
    Write-Host "`nAll $test test(s) matched."
}

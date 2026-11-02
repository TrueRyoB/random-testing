# C++ stress tester

In PowerShell, provide the input generator, program A, and program B in that
order:

```powershell
.\stress_test.ps1 folder\input.cpp folder\solution.cpp folder\brute.cpp
```

If MinGW is not on your `PATH`, give the script the full path to its compiler.
This does not require administrator permission or changing any system setting:

```powershell
.\stress_test.ps1 crossbone\input.cpp crossbone\solution.cpp crossbone\brute.cpp -Compiler "C:\your\mingw\bin\g++.exe"
```

For example, if the installer placed MinGW at `C:\tools\mingw64`, use
`-Compiler "C:\tools\mingw64\bin\g++.exe"`. The path may also be a
compiler command already available on `PATH` (the default is `g++`).
The script automatically adds the chosen compiler's `bin` directory to the
PATH of its compiler and test processes, which also supports MSYS2 UCRT64:

```powershell
.\stress_test.ps1 crossbone\input.cpp crossbone\solution.cpp crossbone\brute.cpp -Compiler "C:\msys64\ucrt64\bin\g++"
```

The script compiles all three sources with `g++ -std=c++17 -O2`, runs the
generator repeatedly, feeds each generated input to both programs, and
compares their output as whitespace-separated tokens.

For a finite run, use `-Iterations`:

```powershell
.\stress_test.ps1 crossbone\input.cpp crossbone\solution.cpp crossbone\brute.cpp -Iterations 1000
```

On the first crash, timeout, or mismatch it stops, prints the generated input,
and writes a timestamped failure directory containing:

- `input.txt` — the exact generated test case
- `program_a.stdout.txt` and `program_b.stdout.txt` — outputs
- matching `.stderr.txt` and `.exit_code.txt` files
- `reason.txt` — why it failed

Use `-TimeoutSeconds 10` to allow ten seconds per generator/program run, or
`-Compiler clang++` to use a different compiler. Compiled programs are kept
in `.stress-build`.

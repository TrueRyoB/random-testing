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

The script compiles all three sources with `g++ -std=c++17 -O2`, runs the
generator repeatedly, feeds each generated input to both programs, and
compares their output as whitespace-separated tokens.

## Special-judge evaluator

Pass `-Evaluator` to use a fourth C++ source as the comparison rule instead
of token-for-token equality:

```powershell
.\stress_test.ps1 folder\input.cpp folder\solution.cpp folder\brute.cpp -Evaluator folder\evaluator.cpp
```

Because it is the fourth positional argument, this is equivalent:

```powershell
.\stress_test.ps1 folder\input.cpp folder\solution.cpp folder\brute.cpp folder\evaluator.cpp
```

The evaluator is invoked once per generated test case with two command-line
arguments:

- `argv[1]` is a UTF-8 file containing Program A's complete standard output.
- `argv[2]` is a UTF-8 file containing Program B's complete standard output.

It must exit with code `0` to accept the pair. Any nonzero exit code rejects
it and stops the stress test. Its standard output and error output are saved
alongside the usual failure artifacts, so it can print an explanation to
`stderr` before rejecting. For example:

```cpp
#include <fstream>
#include <string>

int main(int argc, char** argv) {
    if (argc != 3) return 2;
    std::ifstream answerA(argv[1]), answerB(argv[2]);
    std::string a, b;
    answerA >> a;
    answerB >> b;
    return both_are_valid_and_equivalent(a, b) ? 0 : 1;
}
```

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

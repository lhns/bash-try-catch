# bash-try-catch

Proper error handling for bash.

Migrated from https://gist.github.com/lhns/4ce68fb18979cbf4262fc87f1bff45b1

## Why

`set -e` does not compose. Bash ignores it for every command that runs inside an `if`/`while`/`until` condition or a `&&`, `||` or `!` list, including everything inside functions called from there:

```bash
set -e
deploy() {
  false             # should abort deploy
  echo "deployed"   # but this still runs
}
if ! deploy; then rollback; fi  # rollback is never called
```

Subshells and command substitutions inherit this state.
This library runs the `try` block in one of the few places where bash doesn't ignore `set -e` (see [How it works](#how-it-works)), so errors inside it are always caught, no matter where the code is called from.

## Usage

```bash
source try_catch.sh
```

> [!NOTE]
> `try` and `catch` are aliases. They only work in code that is read *after* `try_catch.sh` was sourced, so `source` it on its own line and before defining functions that use it.
>
> Since bash 5.2 a try/catch directly inside `$( )` or `<( )` can't end with `fi`: bash checks the syntax in there before it expands aliases and fails with ``syntax error near unexpected token `fi'``. Use `yrt` instead of `fi` and `nocatch` instead of `else` there (see [Inside of a command substitution](#inside-of-a-command-substitution)).

Sourcing `try_catch.sh` also enables `set -e -o pipefail` for the calling script.
Inside the try block `set -e -o pipefail` is always active.

### try catch fi

Surround code that might fail with `try` and `catch` to catch any errors that might occur in that section.
The return code can be accessed with `$ERR`.
Variables and functions that are set in the try block are visible in the catch block and afterwards, even if the block failed. So is a `cd`.

```bash
source try_catch.sh

try
  test="hello world"
  # code that could fail
catch
  echo "error code: $ERR" >&2
  echo "$test" # will print "hello world"
  # do something on error
else
  # optional: do something on success
fi

echo "$test" # will print "hello world"
```

### try catcherr fi

`catcherr` works like `catch`, but it also captures stderr of the try block (binary safe, including NUL bytes).
If the block succeeds the captured stderr is printed afterwards. If it fails nothing is printed and the handler can print it by calling `trystderr`.

```bash
source try_catch.sh

try
  echo "my important error message" >&2
  throw
catcherr
  echo "error code: $ERR" >&2
  echo "$(trystderr 2>&1)" # will print "my important error message"
fi
```

`catchvars` is a deprecated alias for `catch`.

### One command

`try ... fi` is a single `if` command. It can be piped, redirected or run in the background as a whole.
A redirection or pipe after `fi` applies to the try block and the catch block (in earlier versions only to the catch block). Like every command in a pipeline, a piped try runs in a subshell, so its variables are not visible afterwards.

```bash
source try_catch.sh

try
  echo "output"
  echo "error message" >&2
  throw
catch
  echo "failed" >&2
fi 2>>error.log | tee output.log
```

### Inside of a command substitution

`yrt` and `nocatch` are aliases for `fi` and `else`. They work everywhere, and they are needed if the try/catch is written directly inside `$( )` or `<( )`:

```bash
source try_catch.sh

output=$(
  try
    curl -f server1.example.com
  catch
    echo "failed with $ERR" >&2
  nocatch
    echo "done" >&2
  yrt
)
```

### throw

Use `throw $STATUS` or just `throw` to raise or rethrow an error. `throw 0` will not raise any error.

```bash
source try_catch.sh

try
  echo "ERROR 3" >&2
  throw 3
catch
  echo "error code: $ERR" >&2
  throw "$ERR"
fi
```

### Empty error handler

To ignore errors in a block just do this:

```bash
source try_catch.sh

try
  # code that could fail
catch :; fi # ignore any errors
```

## Example

```bash
source try_catch.sh

try
  echo "trying server1.example.com" >&2
  curl -f server1.example.com
catch
  echo "failed request to server1.example.com. trying server2.example.com..." >&2
  try
    curl -f server2.example.com
  catch
    echo "failed request to server2.example.com. giving up." >&2
    throw "$ERR"
  fi
fi
```

### return, break, continue and exit

`return`, `break` and `continue` inside the try block work like they would without try/catch: they leave the function or loop that contains the try block and the catch block is not run.
`exit` inside the try block ends the try block with that exit code, like an error.

## How it works

The try block is defined as a function which is run in a subshell (a fork, no new bash is started and no files are written). Inside the subshell `set -eET -o pipefail` and `shopt -s inherit_errexit` are active.
The subshell is a command substitution in the word list of a `for` loop, where bash doesn't ignore `set -e`. There is one case where it still does: if the caller itself runs inside a command substitution whose failure is ignored, like `if x=$(f)` or `x=$(f) || ...`. An ERR trap detects that, and then the block runs in a trap handler of another subshell, which is not affected (for `SIGURG`, or `SIGUSR2`, `SIGUSR1` or `SIGALRM` if it can't be trapped). That takes one more fork.
None of this is documented behavior of bash, so the library tests the last resort when it is sourced and fails with an error message if it doesn't work.
When the block is done, the subshell sends back what changed and the caller applies it, as if the block had run inline:
- variables, as plain assignments in the scope of the caller (globals stay global and locals of the calling function stay local), including attributes (`export`, `readonly`, `-i`, `-l`, `-u`, namerefs); unset variables are unset
- variables declared with `local` or `declare` in the try block become local variables of the calling function (global outside of functions, like `declare` there)
- functions (only if one was changed), aliases, shell options (`set -o`, `shopt`), traps for signals, `umask`, `ulimit`, the working directory and the directory stack
- positional parameters (`shift`, `set --`)

An ERR trap of the caller runs for errors in the try block if it would run for the same code outside of it (outside of functions or with `set -E`).

- Everything is serialized with `printf %q` and arrays are assigned element by element, so it is binary safe. Only NUL bytes are impossible in bash variables. The stderr captured by `catcherr` keeps NUL bytes as well.
- When bash exits a subshell because of `set -e`, the local variables of all functions are already gone when the EXIT trap runs. That's why errors are handled in an ERR trap that returns from one function after another until the try block itself returned and the variables of the caller are visible again. `exit` does the same with a DEBUG trap (`extdebug`). `local -p` tells the local variables of the try block apart (before bash 5.1 it can't, there every variable is declared with `local` again, which only keeps the value of a variable that already is local).
- `return` is an alias for `builtin return` that also records the depth of the function it returns from. That's how a `return` in the try block itself is told apart from a `return` in a function called from it.
- `break` and `continue` can't leave a function, so the try block runs inside 10 loops that catch them and they are repeated by the caller. Beyond 10 loops `$_` (the argument of `break`/`continue`) is used.
- The results are passed through the pipe of the command substitution. Only a small relay process keeps that pipe open, the subshell sends its results to the relay as messages with a length. So background jobs started in the try block don't keep `catch` waiting.
- Only what the try block changed is passed back. The subshell keeps a copy of all variables before the block and compares them byte by byte afterwards, so unchanged values are never quoted or sent. Functions, `umask` and limits can only be printed: the relay prints them before the block (while the block runs) and compares that with what the subshell prints after it.
- The library doesn't depend on the caller's `IFS`, `nocasematch`, `xtrace` or functions that shadow builtins (it calls them with `builtin`, except `local`, `declare`, `exec` and `eval`). With `set -x` the functions of the library are not traced, only the try block and the few commands of the `catch` alias. It doesn't change `BASH_REMATCH`.

## Limitations

Not passed back from the try block:
- Variables that bash sets itself, like `RANDOM`, `SECONDS` or `BASH_SOURCE`, and EXIT and ERR traps (they run when the try block ends). `BASH_REMATCH` is passed back since bash 5.1, it is readonly before.
- File descriptors that are opened or closed with `exec`, `$!` and background jobs: they belong to the subshell, so `wait` doesn't work for them after the try block.
- Nothing is passed back if bash exits the subshell without an ERR trap, e.g. because of `set -u`, `builtin exit` or `exit` in an EXIT trap of the block. `$ERR` is still the exit code.
- `unset` of a variable that is local to a function further up the call stack (not the caller itself) makes a global variable with the same name visible. That is passed back as an assignment to the local variable.
- The options `errexit`, `errtrace`, `functrace`, `pipefail`, `extdebug` and `inherit_errexit` are set by the library for the block and not passed back.
- Variables that are declared but not set in the try block (`local x` without a value) are not passed back.
- Hard limits (`ulimit -H`) can only be lowered.

Not passed into the try block:
- Traps for signals of the caller (a subshell resets them). The caller still runs them when it gets the signal.

Control flow and errors:
- `throw` outside of a try block (e.g. in the catch block) relies on `set -e` of the caller. In code that is called from a context where bash ignores `set -e`, use `return`/`exit` there or make sure `throw` is the last command.
- The usual gaps of `set -e` still apply inside the block, e.g. `local x=$(false)` or errors inside a function that is called in an `if` condition.
- If the code with the try block runs inside a command substitution whose failure is ignored (`if x=$(f)`, `x=$(f) || ...`), bash ignores `set -e` in all command substitutions inside the try block. Only their exit code counts there: `y=$(false)` fails the block, `y=$(false; echo z)` doesn't. Commands of the block itself and functions are not affected. `wait -n` doesn't see a background job there that has already ended.
- A try block that ends with a failing command (e.g. `[[ $x ]] && y`) counts as failed, like a function would.
- `break N`/`continue N` with N greater than 10 from inside a loop in the try block leaves as many loops of the caller as N, not N minus the loops inside the block.
- `break`/`continue` in a try block that is not inside a loop ends the try block (bash prints an error and would continue the block).
- An ERR trap of the caller that runs for an error in the try block sees `LINENO` and `FUNCNAME` of the library, not of the failed command.
- `ERR` and `trystderr` belong to the last try. Copy `$ERR` before using another try in a catch block, e.g. before `throw "$ERR"`.

Side effects:
- Inside the try block `trap`, `exit` and `wait` are shell functions: EXIT and ERR traps of the block must not replace the internal ones, and `wait` without process ids must not wait for the processes of the library. Functions of the caller with these names are kept, but not called inside the try block.
- Inside the try block `FUNCNAME`, `BASH_SOURCE`, `BASH_LINENO` and `caller` contain five functions of the library between the block and its caller. `BASH_SUBSHELL` and `$BASHPID` are those of the subshell.
- `return` is an alias everywhere after `try_catch.sh` was sourced. It behaves like the builtin.
- A function that uses try/catch contains the expanded aliases (see `declare -f`). It only works where the library is sourced, e.g. not in another bash after `export -f`.
- `ERR`, `TRY_INTERNAL_*` and `try_internal_*` are used by the library, and so are the aliases `try`, `catch`, `catcherr`, `catchvars`, `yrt`, `nocatch` and `return`.
- While the try block runs, the library uses file descriptors between 100 and 254. Don't close or replace descriptors in that range that the block didn't open.
- POSIX mode (`set -o posix`, `bash --posix`) is not supported: functions can't replace `exit` and `trap` there. Note that `set +o posix` turns `expand_aliases` off, so the aliases need `shopt -s expand_aliases` again.

Syntax:
- `fi` and `else` of a try/catch can't be used directly inside `$( )` and `<( )` since bash 5.2, use `yrt` and `nocatch` there (see [Usage](#usage)).
- An empty try block must be written as `try catch ...` or on separate lines, `try; catch` is a syntax error.

Other:
- Every try forks four times: the subshell, the relay and two command substitutions that print the functions. One more fork if the caller has an ERR trap that applies, one more inside a command substitution whose failure is ignored, and three more with more than 200 variables (to list them). On Git Bash for Windows, where a fork alone takes about 40 ms, a try takes about 180 ms.
- Every try looks at all variables twice and prints all functions of the script twice, so it gets slower with a lot of shell state: on Git Bash about 0.4 ms per variable and 1 ms per KB of functions. The size of unchanged values hardly matters, a changed value costs about 1.3 ms per KB.
- `catcherr` reads stderr until it is closed, so it waits for background jobs of the try block that still have stderr open. Give jobs that keep running another stderr, e.g. `job 2>/dev/null &`. The captured stderr is printed after the block, not interleaved with stdout. It is read byte by byte to keep NUL bytes: about 50 KB per second on Git Bash, and every NUL byte costs extra time (about 5000 per second).
- If the subshell is killed (e.g. `SIGKILL`) while background jobs of the block still run, `catch` waits for them.
- Background jobs that were started before the try block are not children of the subshell. `wait` for one of them in the try block fails with 127 (`not a child of this shell`), so the block fails even if the job succeeds. `jobs` and `%1` don't know them either, and `$!` is not the caller's last job at the start of the block, so save it in a variable before the block if you need it. `wait` without process ids only waits for the jobs of the block.
- Requires bash 4.4 or newer. Tested with bash 4.4, 5.0, 5.1, 5.2 and 5.3.
- MSYS2/Git Bash drops `\r` in compound array assignments like `local -a x=($'\r')`, with or without this library.

## License

This project uses the Apache 2.0 License. See the file called LICENSE.

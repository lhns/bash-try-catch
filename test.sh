source try_catch.sh

assert() {
  local expected_exit="$1"
  local expected_out="$2"
  local expected_err="$3"
  shift 3
  (
    set +e
    obtained="$(
      exec {tmp}>&1
      (
        (
          "$@"
          echo "exit: $?" >&${tmp}
        ) | while IFS= read -r line; do echo "stdout: $line"; done >&${tmp}
      ) 2>&1 | while IFS= read -r line; do echo "stderr: $line"; done
      exec {tmp}<&-
    )"
    obtained_exit="$(printf %s "$obtained" | grep "^exit: " | sed -e 's/^exit: //')"
    obtained_out="$(printf %s "$obtained" | grep "^stdout: " | sed -e 's/^stdout: //')"
    obtained_err="$(printf %s "$obtained" | grep "^stderr: " | sed -e 's/^stderr: //')"
    error=0
    if [[ "$expected_exit" != "$obtained_exit" ]]; then error=1; echo "unexpected exit code! expected: $expected_exit, obtained: $obtained_exit"; fi
    if [[ "$expected_out" != "$obtained_out" ]]; then error=1; echo "unexpected stdout! expected: '$expected_out', obtained: '$obtained_out'"; fi
    if [[ "$expected_err" != "$obtained_err" ]]; then error=1; echo "unexpected stderr! expected: '$expected_err', obtained: '$obtained_err'"; fi
    return "$error"
  )
}

# Tests

F() { test=0; try test=1; echo testout; echo testerr >&2; true; catch echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\ntest 0' $'testerr' F
F() { test=0; try test=1; echo testout; echo testerr >&2; throw 2; catch echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\nerror 2\ntest 0' $'testerr' F
F() { test=0; try test=1; echo testout; echo testerr >&2; true; catchvars echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\ntest 1' $'testerr' F
F() { test=0; try test=1; echo testout; echo testerr >&2; throw 2; catchvars echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\nerror 2\ntest 1' $'testerr' F
F() { test=0; try test=1; echo testout; echo testerr >&2; true; catcherr echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\ntest 1' $'testerr' F
F() { test=0; try test=1; echo testout; echo testerr >&2; throw 2; catcherr echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\nerror 2\ntest 1' $'' F
F() { test=0; try test=1; echo testout; echo testerr >&2; throw 2; catcherr echo "error $ERR"; fi; echo "test $test"; echo "stderr $(trystderr 2>&1)"; }; assert 0 $'testout\nerror 2\ntest 1\nstderr testerr' $'' F

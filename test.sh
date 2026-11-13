set -e
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
    if [[ "$error" != 0 ]]; then echo "in line ${BASH_LINENO[0]}: $(sed -n "${BASH_LINENO[0]}p" "${BASH_SOURCE[1]}")"; fi
    return "$error"
  )
}

# Tests

F() { test=0; try test=1; echo testout; echo testerr >&2; true; catch echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\ntest 1' $'testerr' F
F() { test=0; try test=1; echo testout; echo testerr >&2; throw 2; catch echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\nerror 2\ntest 1' $'testerr' F
F() { test=0; try test=1; echo testout; echo testerr >&2; true; catchvars echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\ntest 1' $'testerr' F
F() { test=0; try test=1; echo testout; echo testerr >&2; throw 2; catchvars echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\nerror 2\ntest 1' $'testerr' F
F() { test=0; try test=1; echo testout; echo testerr >&2; true; catcherr echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\ntest 1' $'testerr' F
F() { test=0; try test=1; echo testout; echo testerr >&2; throw 2; catcherr echo "error $ERR"; fi; echo "test $test"; }; assert 0 $'testout\nerror 2\ntest 1' $'' F
F() { test=0; try test=1; echo testout; echo testerr >&2; throw 2; catcherr echo "error $ERR"; fi; echo "test $test"; echo "stderr $(trystderr 2>&1)"; }; assert 0 $'testout\nerror 2\ntest 1\nstderr testerr' $'' F

# errexit applies in the try block even if the caller is in a context where bash ignores errexit
F() { G() { try false; echo reached; catch echo "error $ERR"; fi; }; if G; then echo ok; fi; }; assert 0 $'error 1\nok' $'' F
F() { G() { try false; echo reached; catch echo "error $ERR"; fi; }; G || echo failed; }; assert 0 $'error 1' $'' F
F() { G() { try false; echo reached; catch echo "error $ERR"; throw 3; fi; }; if ! G; then echo failed; fi; }; assert 0 $'error 1\nfailed' $'' F
F() { G() { false; echo reached; }; try G; echo reached; catch echo "error $ERR"; fi; }; assert 0 $'error 1' $'' F
F() { try false | true; echo reached; catch echo "error $ERR"; fi; }; assert 0 $'error 1' $'' F

# nesting
F() { try try false; echo reached; catch echo "inner $ERR"; throw 7; fi; echo reached; catch echo "outer $ERR"; fi; }; assert 0 $'inner 1\nouter 7' $'' F
F() { try throw 2; catch try throw 3; catch echo "inner $ERR"; fi; fi; }; assert 0 $'inner 3' $'' F
F() { ( set -e; try throw 3; catch throw "$ERR"; fi; echo reached ); }; assert 3 $'' $'' F
F() { try true; catch echo "error $ERR"; else echo "no error"; fi; }; assert 0 $'no error' $'' F

# variables
F() { G() { try g=1; catch :; fi; after=1; }; g=0; G; echo "g=$g after=$after"; }; assert 0 $'g=1 after=1' $'' F
F() { G() { local l=0; try l=1; catch :; fi; echo "l=$l"; }; G; echo "l=${l-unset}"; }; assert 0 $'l=1\nl=unset' $'' F
F() { G() { try local l=1; catch :; fi; echo "l=${l-unset}"; }; G; echo "global l=${l-unset}"; }; assert 0 $'l=1
global l=unset' $'' F
F() { try a=(x $'y\nz'); declare -gA m=([k]=v); catch :; fi; echo "${#a[@]} ${a[1]} ${m[k]}"; }; assert 0 $'2 y\nz v' $'' F
F() { declare -A m=([a]=1); a=(1); try m[b]=2; a+=(2); throw; catch :; fi; echo "${m[a]}${m[b]} ${a[*]}"; }; assert 0 $'12 1 2' $'' F
F() { u=1; try unset u; catch :; fi; echo "u=${u-unset}"; }; assert 0 $'u=unset' $'' F
F() { try export EXPORTED=1; catch :; fi; bash -c 'echo "EXPORTED=$EXPORTED"'; }; assert 0 $'EXPORTED=1' $'' F
F() { G() { echo "g $1"; }; x=1; try G "$x"; catch :; fi; }; assert 0 $'g 1' $'' F
F() { G() { try echo "args $*"; catch :; fi; }; G a b; }; assert 0 $'args a b' $'' F
F() { G() { try shift; set -- "$@" z; catch :; fi; echo "$# $*"; }; G a b; }; assert 0 $'2 b z' $'' F
F() { G() { try set -- ''; catch :; fi; echo "$#"; }; G a b; }; assert 0 $'1' $'' F
F() { G() { try shift; throw; catch echo "error $ERR $1"; fi; }; G a b; }; assert 0 $'error 1 b' $'' F
F() { G() { try local -i n=1; local -A m=([k]=v); local -r r=1; local -x e=1; catch :; fi; n+=1; echo "$n ${m[k]} ${m@a} ${r@a} ${e@a}"; }; G; echo "${n-unset}"; }; assert 0 $'2 v A r x\nunset' $'' F
F() { G() { try declare -gA gm=([k]=v); catch :; fi; }; G; echo "${gm[k]} ${gm@a}"; }; assert 0 $'v A' $'' F
F() { G() { x=1; try local -n r=x; catch :; fi; r=5; echo "$x"; [[ -R r ]] && echo nameref; }; G; }; assert 0 $'5\nnameref' $'' F
F() { n=1; try declare -gi n; catch :; fi; n+=1; echo "$n"; }; assert 0 $'2' $'' F
F() { up=a; try declare -gu up; catch :; fi; up+=b; echo "$up"; }; assert 0 $'AB' $'' F
F() { try ro=1; readonly ro; catch :; fi; ( ro=2 ) 2>/dev/null || echo "readonly ok"; }; assert 0 $'readonly ok' $'' F

# environment and options
F() { d="$PWD"; try cd /; catch :; fi; echo "$PWD $(pwd)"; cd "$d"; }; assert 0 $'/ /' $'' F
F() { set -u; try echo ok; catch :; fi; }; assert 0 $'ok' $'' F
F() { try set -f; shopt -s nullglob; catch :; fi; [[ $- == *f* ]] && echo noglob; shopt -q nullglob && echo nullglob; set +f; shopt -u nullglob; }; assert 0 $'noglob\nnullglob' $'' F
F() { set +e +o pipefail; try :; catch :; fi; [[ $- == *e* ]] && echo BUG; [[ -o pipefail ]] && echo BUG; echo "options kept"; }; assert 0 $'options kept' $'' F
F() { try alias hi='echo hi'; catch :; fi; eval hi; alias bye='echo bye'; try unalias bye; catch :; fi; alias bye 2>/dev/null || echo "bye gone"; }; assert 0 $'hi\nbye gone' $'' F
F() { umask 022; try umask 077; catch :; fi; umask; }; assert 0 $'0077' $'' F
F() { d="$(mktemp -d)"; try pushd -n "$d" >/dev/null; catch :; fi; [[ ${DIRSTACK[1]} == "$d" ]] && echo "dirstack ok"; dirs -c; rmdir "$d"; }; assert 0 $'dirstack ok' $'' F
F() { ulimit -S -c unlimited 2>/dev/null; try ulimit -S -c 0; catch :; fi; ulimit -S -c; }; assert 0 $'0' $'' F
F() { try trap 'echo usr1' USR1; catch :; fi; trap -p USR1; trap - USR1; }; assert 0 $'trap -- \'echo usr1\' SIGUSR1' $'' F
F() { set -E; trap 'echo "caller err $?"' ERR; try false; catch echo "error $ERR"; fi; trap - ERR; set +E; }; assert 0 $'caller err 1\nerror 1' $'' F
F() { eval "$(printf 'for l%d in 1 2; do ' {1..12}) try break 12; catch :; fi; echo BUG; $(printf 'done; %.0s' {1..12}) echo done"; }; assert 0 $'done' $'' F
F() { set +o pipefail; try echo err >&2; throw 3; catcherr echo "error $ERR"; fi; }; assert 0 $'error 3' $'' F
F() { v=0; try v=1; trap 'echo "exit trap v=$v"' EXIT; catch :; fi; echo "v=$v"; }; assert 0 $'exit trap v=1\nv=1' $'' F
F() { try trap 'echo "err trap $?"' ERR; G() { false; }; G; catch echo "error $ERR"; fi; }; assert 0 $'err trap 1\nerror 1' $'' F
F() { G() { local l=0; try l=1; H() { local h=1; exit 4; }; H; catch echo "error $ERR l=$l h=${h-unset}"; fi; }; G; }; assert 0 $'error 4 l=1 h=unset' $'' F
F() { G() { local l=0; try l=1; H() { local h=1; false; }; H; catch echo "error $ERR l=$l h=${h-unset}"; fi; }; G; }; assert 0 $'error 1 l=1 h=unset' $'' F
F() { try set +e; false; echo "continued"; set -e; catch echo "error $ERR"; fi; }; assert 0 $'continued' $'' F
F() { try x=$(false); echo "x=$x"; catch echo "error $ERR"; fi; }; assert 0 $'error 1' $'' F
F() { try ( false; echo reached ); catch echo "error $ERR"; fi; }; assert 0 $'error 1' $'' F
F() { try x=$(false; echo reached); echo "x=$x"; catch echo "error $ERR"; fi; }; assert 0 $'error 1' $'' F
F() { { try echo piped; catch :; fi; } | tr a-z A-Z; }; assert 0 $'PIPED' $'' F
F() { SECONDS=0; try sleep 3 >/dev/null 2>&1 & catch :; fi; echo "waited $((SECONDS >= 3))"; }; assert 0 $'waited 0' $'' F
F() { SECONDS=0; try { sleep 2; echo late >&2; } >/dev/null & echo early >&2; catcherr :; fi; echo "waited $((SECONDS >= 2))"; }; assert 0 $'waited 1' $'early\nlate' F

# wait in the try block: its own jobs, not the relay or the reader, and not the jobs of the caller
F() { try sleep 0.2 & wait; echo "rc=$?"; catch :; fi; }; assert 0 $'rc=0' $'' F
F() { try echo e >&2; (sleep 0.2; exit 3) & wait; wait -n || echo "none $?"; catcherr :; fi; }; assert 0 $'none 127' $'e' F
F() { try (sleep 0.3; exit 4) & (sleep 0.1; exit 0) & wait -n; echo "first $?"; wait -n; catch echo "error $ERR"; fi; }; assert 0 $'first 0\nerror 4' $'' F
F() { try (sleep 0.1; exit 3) & wait $!; catch echo "error $ERR"; fi; }; assert 0 $'error 3' $'' F
F() { sleep 0.3 & try wait $!; catcherr echo "error $ERR"; fi; wait; }; assert 0 $'error 127' $'' F
F() { try ( sleep 0.1 & wait; echo sub ); catch :; fi; }; assert 0 $'sub' $'' F
F() { wait() { echo mine; }; try :; catch :; fi; wait; unset -f wait; }; assert 0 $'mine' $'' F

# return
F() { G() { try v=1; return 3; echo reached; catch echo "error $ERR"; fi; echo reached; }; G; echo "rc=$? v=$v"; }; assert 0 $'rc=3 v=1' $'' F
F() { G() { try return; catch echo "error $ERR"; fi; echo reached; }; G; echo "rc=$?"; }; assert 0 $'rc=0' $'' F
F() { G() { try H() { return 5; }; H || echo "h $?"; catch echo "error $ERR"; fi; echo after; }; G; }; assert 0 $'h 5\nafter' $'' F
F() { G() { try try return 4; catch echo inner; fi; echo reached; catch echo outer; fi; echo reached; }; G; echo "rc=$?"; }; assert 0 $'rc=4' $'' F
F() { G() { try throw 6; catch return 7; fi; echo reached; }; G; echo "rc=$?"; }; assert 0 $'rc=7' $'' F

# break and continue
F() { for i in 1 2 3; do try v=$i; if [[ $i == 2 ]]; then break; fi; catch echo "error $ERR"; fi; echo "i=$i"; done; echo "v=$v"; }; assert 0 $'i=1\nv=2' $'' F
F() { for i in 1 2 3; do try if [[ $i == 2 ]]; then continue; fi; echo "in $i"; catch :; fi; echo "i=$i"; done; }; assert 0 $'in 1\ni=1\nin 3\ni=3' $'' F
F() { for i in 1 2; do for j in a b; do try if [[ $j == a ]]; then break 2; fi; catch :; fi; done; done; echo "i=$i j=$j"; }; assert 0 $'i=1 j=a' $'' F
F() { for i in 1 2; do for j in a b; do try if [[ $j == a ]]; then continue 2; fi; catch :; fi; echo "BUG"; done; done; echo "i=$i j=$j"; }; assert 0 $'i=2 j=a' $'' F
F() { for i in 1 2; do try for j in a b c; do [[ $j == b ]] && break; echo "j=$j"; done; echo "inner loop done"; catch :; fi; done; }; assert 0 $'j=a\ninner loop done\nj=a\ninner loop done' $'' F
F() { try catch echo "error $ERR"; else echo "empty ok"; fi; }; assert 0 $'empty ok' $'' F

# exit
F() { G() { local l=0; try l=1; H() { local h=1; g=1; exit 4; }; H; echo reached; catch echo "error $ERR l=$l h=${h-unset} g=$g"; fi; }; G; }; assert 0 $'error 4 l=1 h=unset g=1' $'' F
F() { G() { try if H() { exit 3; }; H; then echo reached; fi; echo reached; catch echo "error $ERR"; fi; }; G; }; assert 0 $'error 3' $'' F
F() { try ( exit 5 ); echo reached; catch echo "error $ERR"; fi; }; assert 0 $'error 5' $'' F
F() { try exit 0; echo reached; catch echo "error $ERR"; else echo "exit 0 ok"; fi; }; assert 0 $'exit 0 ok' $'' F
F() { G() { local l=0; try l=1; set -u; echo "$undefined_variable"; catcherr echo "error $ERR l=$l"; fi; }; G; }; assert 0 $'error 1 l=0' $'' F

# functions
F() { try newf() { echo "newf"; }; catch :; fi; newf; }; assert 0 $'newf' $'' F
F() { oldf() { :; }; try unset -f oldf; catch :; fi; declare -F oldf || echo gone; }; assert 0 $'gone' $'' F
F() { oldf() { echo old; }; try oldf() { echo new; }; throw; catch :; fi; oldf; }; assert 0 $'new' $'' F
F() { eval $'multi() { x="\nfake () \n"; }'; gone() { :; }; try unset -f gone; catch :; fi; declare -F gone || echo gone; declare -F multi; }; assert 0 $'gone\nmulti' $'' F
F() { ex() { :; }; export -f ex; try :; catch :; fi; bash -c 'declare -F ex'; }; assert 0 $'ex' $'' F

# attributes of variables that were not changed are kept
F() { declare -i n=1; declare -l low=a; try :; catch :; fi; n+=1; low+=B; echo "$n $low"; }; assert 0 $'2 ab' $'' F

# stderr with NUL bytes
F() { try printf 'a\0b\n' >&2; throw; catcherr trystderr 2>&1 | tr '\0' 0; fi; }; assert 0 $'a0b' $'' F
F() { echo input | { try read -r line; echo "read $line"; catch :; fi; }; }; assert 0 $'read input' $'' F
F() { try printf 'a\n\n' >&2; catcherr :; fi; echo "[$(trystderr 2>&1; echo .)]"; }; assert 0 $'[a\n\n.]' $'a' F

# state of the caller that must not break the library
F() { IFS=$'\n\t'; try w=4; false; catch echo "ERR=$ERR w=$w"; fi; }; assert 0 $'ERR=1 w=4' $'' F
F() { IFS=; try w=4; false; catch echo "ERR=$ERR w=$w"; fi; }; assert 0 $'ERR=1 w=4' $'' F
F() { shopt -s nocasematch; try arr=(a b); set +e; false; echo continued; catch :; fi; echo "${arr@a}"; shopt -u nocasematch; }; assert 0 $'continued\na' $'' F
F() { printf() { :; }; echo() { :; }; read() { :; }; try v=1; catch :; fi; unset -f printf echo read; builtin echo "v=$v"; }; assert 0 $'v=1' $'' F
F() { set -u; source <(builtin echo 'builtin echo in; return 3; echo no'); builtin echo "rc=$?"; }; assert 0 $'in\nrc=3' $'' F
F() { bash --posix -c 'source ./try_catch.sh' 2>&1; echo "rc=$?"; }; assert 0 $'try_catch.sh: POSIX mode is not supported\nrc=1' $'' F
F() { ( set -x; try echo e >&2; throw; catcherr :; fi; { set +x; } 2>/dev/null; trystderr 2>&1 | grep -c TRY_INTERNAL || : ) 2>/dev/null; }; assert 0 $'0' $'' F
F() { try exec 10>/dev/null; v=1; catch :; fi; echo "${v-unset}"; }; assert 0 $'1' $'' F
F() { ( try set -x; try :; catch :; fi; catch :; fi; { [[ -o xtrace ]] && echo propagated; set +x; } 2>/dev/null ) 2>/dev/null; }; assert 0 $'propagated' $'' F
F() { set -o posix; try :; catch echo "ERR=$ERR"; fi; set +o posix; shopt -s expand_aliases; }; assert 0 $'ERR=2' $'try_catch.sh: POSIX mode is not supported' F

# more cases
F() { try ( try false; catch echo "caught $ERR"; fi ); catch :; fi; }; assert 0 $'caught 1' $'' F
F() { try false || exit; catch echo "ERR=$ERR"; fi; }; assert 0 $'ERR=1' $'' F
F() { try ( true; exit ) && echo ok; catch :; fi; }; assert 0 $'ok' $'' F
F() { G() { try echo err >&2; return 4; catcherr echo no; fi; }; G; echo "rc=$?"; }; assert 0 $'rc=4' $'err' F
F() { arr=(1 2 3); try unset arr; arr=hello; catch :; fi; echo "${arr[*]} ${#arr[@]}"; }; assert 0 $'hello 1' $'' F
F() { x=(1 2); try unset x; declare -gA x=([k]=v); catch :; fi; echo "${x@a} ${!x[*]}"; }; assert 0 $'A k' $'' F
F() { declare -gi n=5; try declare -g +i n; n=hello; catch :; fi; echo "$n"; }; assert 0 $'hello' $'' F
F() { bash -c $'source ./try_catch.sh\ntry declare -A m=([a]=1); declare -i num=3; catch :; fi; echo "${m[a]} ${num@a}"'; }; assert 0 $'1 i' $'' F
F() { try ( trap 'echo bye' EXIT; echo in ); catch :; fi; }; assert 0 $'in\nbye' $'' F
F() { try -n() { echo dash; }; catch :; fi; -n; }; assert 0 $'dash' $'' F
F() { exit() { builtin exit "$@"; }; try :; catch :; fi; declare -F exit; unset -f exit; }; assert 0 $'exit' $'' F
F() { d="$PWD"; try cd /; cd "$d"; catch :; fi; echo "$OLDPWD"; }; assert 0 $'/' $'' F
F() { try trap 'echo x' EXIT; trap -p EXIT; catch :; fi; }; assert 0 $'trap -- echo\\ x EXIT\nx' $'' F
F() { big="$(printf '%*s' 300000 '')"; SECONDS=0; try big+=x; catch :; fi; echo "${#big} $((SECONDS < 20))"; }; assert 0 $'300001 1' $'' F

# try ... fi is one command
F() { try echo out; false; catch echo "caught $ERR"; fi | sed 's/^/P:/'; }; assert 0 $'P:out\nP:caught 1' $'' F
F() { try echo out; echo err >&2; false; catch echo caught; echo err >&2; fi >/dev/null 2>&1; echo done; }; assert 0 $'done' $'' F
F() { try echo bg; false; catch echo "caught $ERR"; fi & wait; }; assert 0 $'bg\ncaught 1' $'' F
F() { try true; catch :; elif true; then echo elif; fi; }; assert 0 $'elif' $'' F
F() { x=`try echo in; false; catch echo "caught $ERR"; fi`; echo "$x"; }; assert 0 $'in\ncaught 1' $'' F
F() { G() { x=`try false; echo reached; catch echo "caught $ERR"; fi`; echo "$x"; }; if G; then :; fi; }; assert 0 $'caught 1' $'' F
# yrt and nocatch instead of fi and else: bash 5.2 and newer check the syntax in $( ) and <( ) before they expand aliases
F() { x=$(try echo in; false; catch echo "caught $ERR"; yrt); echo "$x"; cat <(try false; catch echo "caught $ERR"; yrt); }; assert 0 $'in\ncaught 1\ncaught 1' $'' F
F() { x=$(try echo in; catch echo no; nocatch echo fine; yrt); echo "$x"; }; assert 0 $'in\nfine' $'' F
F() { try true; catch :; nocatch try echo e >&2; throw 5; catcherr echo "inner $ERR $(trystderr 2>&1)"; yrt; yrt; }; assert 0 $'inner 5 e' $'' F
F() {
  G() {
    local x
    x=$(
      try
        v=1
        false
        echo reached
      catch
        echo "caught $ERR v=$v"
      nocatch
        echo no
      yrt
    )
    echo "$x"
  }
  if G; then :; fi
}; assert 0 $'caught 1 v=1' $'' F
F() { G() { try false; echo reached; catch echo "caught $ERR"; fi; }; if x=$(G); then echo "$x"; fi; }; assert 0 $'caught 1' $'' F
# in a command substitution whose failure is ignored, bash ignores errexit everywhere but in the trap handler of a subshell
F() { G() { local v=1; try v=2; H; echo reached; catch echo "caught $ERR v=$v"; fi; }; H() { false; echo reached; }; x=$(G) || :; echo "$x"; }; assert 0 $'caught 1 v=2' $'' F
F() { G() { try echo e >&2; try false; catch echo inner; fi; exit 4; catcherr echo "ERR=$ERR $(trystderr 2>&1)"; fi; }; if x=$(G); then echo "$x"; fi; }; assert 0 $'inner\nERR=4 e' $'' F
F() { G() { try return 3; catch :; fi; echo reached; }; if x=$(G); then echo "$x"; else echo "rc=$?"; fi; }; assert 0 $'rc=3' $'' F
F() { G() { try trap 'echo usr1' USR1; kill -USR1 "$BASHPID"; trap -p USR1; catch :; fi; }; if x=$(G); then echo "$x"; fi; }; assert 0 $'usr1\ntrap -- \'echo usr1\' SIGUSR1' $'' F

# bash versions: "local -" turns expand_aliases off in 4.4, "local -p NAME" succeeds for all variables before 5.1
F() { try :; catch :; fi; shopt -q expand_aliases && echo on; eval 'try echo a; false; catch echo b; fi'; }; assert 0 $'on\na\nb' $'' F
F() { n=1; G() { try declare -gi n; n+=1; catch :; fi; }; G; echo "$n ${n@a}"; }; assert 0 $'2 i' $'' F
F() { G() { local -A m; try m[k]=v; catch :; fi; echo "${m[k]}"; }; G; echo "${m[k]-unset}"; }; assert 0 $'v\nunset' $'' F
F() { g=1; G() { local l=1; try local b=1; g=2; l=2; catch :; fi; echo "$b $g $l"; }; G; echo "${b-unset} $g ${l-unset}"; }; assert 0 $'1 2 2\nunset 2 unset' $'' F
F() { t=1; G() { try local -n ref=t; ref=2; catch :; fi; ref=3; }; G; echo "$t ${ref-unset}"; }; assert 0 $'3 unset' $'' F
F() { shopt -s localvar_inherit 2>/dev/null || :; g=1; G() { try g=2; local b=1; catch :; fi; }; G; echo "$g ${b-unset}"; }; assert 0 $'2 unset' $'' F
F() { set -f; try a='*'; catch :; fi; echo $a; [[ -o noglob ]] && echo noglob; }; assert 0 $'*\nnoglob' $'' F
F() { [[ abc =~ (b)(c) ]]; try :; catch :; fi; echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; }; assert 0 $'bc' $'' F
# BASH_REMATCH is readonly before bash 5.1
if ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))); then
  F() { try [[ abc =~ (b)(c) ]]; false; catch echo "${BASH_REMATCH[1]}"; fi; echo "${BASH_REMATCH[2]} ${#BASH_REMATCH[@]}"; }; assert 0 $'b
c 3' $'' F
fi
F() { try BASH_ENV=/dev/null; catch :; fi; echo "$BASH_ENV"; }; assert 0 $'/dev/null' $'' F

# found in review
F() { IFS=:; try :; catch :; fi; echo "[$IFS]"; try IFS=,; catch :; fi; echo "[$IFS]"; }; assert 0 $'[:]\n[,]' $'' F
F() { shopt -s nocasematch; IFS=:; try :; catch :; fi; shopt -q nocasematch && echo kept; }; assert 0 $'kept' $'' F
F() { try builtin exit 4; catch echo "error $ERR"; fi; }; assert 0 $'error 4' $'' F
F() { g=0; G() { try g=1; catch :; fi; g=2; }; G; echo "$g"; }; assert 0 $'2' $'' F
F() { try (exit 3) & sleep 0.3; wait -n || echo "rc $?"; wait -n || echo "rc $?"; catch :; fi; }; assert 0 $'rc 3\nrc 127' $'' F
F() { try BASHFOO=1; BASH_MYVAR=2; COMP_X=3; catch :; fi; echo "$BASHFOO $BASH_MYVAR $COMP_X"; }; assert 0 $'1 2 3' $'' F
F() { try ev=1; trap 'echo bye; exit 7' EXIT; catch echo "error $ERR ${ev-unset}"; fi; }; assert 0 $'bye\nerror 7 unset' $'' F
F() { try trap 'echo x' USR1; trap - "$(kill -l USR1)"; catch :; fi; trap -p USR1; echo end; }; assert 0 $'end' $'' F
F() { set -a; try ax=1; catch :; fi; set +a; env | grep -c '^TRY_INTERNAL_' || :; echo "${ax@a}"; }; assert 0 $'0\nx' $'' F

# binary safety: every byte (bash variables can't contain NUL, stderr can)
all=; for i in {1..255}; do printf -v c "\\x$(printf %02x "$i")"; all+="$c"; done
same() { [[ $1 == "$2" ]] && echo "$3 ok" || echo "$3 differs"; }
F() { try v="$all"; a=(x "$all"); declare -gA m=(); m["k$all"]="$all"; catch :; fi; same "$v" "$all" scalar; same "${a[1]}" "$all" array; same "${m["k$all"]}" "$all" assoc; }; assert 0 $'scalar ok\narray ok\nassoc ok' $'' F
F() { v="$all"; try :; catch :; fi; same "$v" "$all" unchanged; try f() { printf %s "$all"; }; catch :; fi; same "$(f)" "$all" function; }; assert 0 $'unchanged ok\nfunction ok' $'' F
F() { try LC_ALL=C; v="$all"; catch :; fi; same "$v" "$all" "other locale"; }; assert 0 $'other locale ok' $'' F
F() { try printf '\0%s\0' "$all" >&2; throw; catcherr same "$(trystderr 2>&1 | od -An -tx1)" "$(printf '\0%s\0' "$all" | od -An -tx1)" stderr; fi; }; assert 0 $'stderr ok' $'' F
F() { G() { try printf '\0%s\0' "$all" >&2; catcherr :; fi; }; same "$(G 2>&1 | od -An -tx1)" "$(printf '\0%s\0' "$all" | od -An -tx1)" replay; }; assert 0 $'replay ok' $'' F
# (macOS rejects file names that are not valid UTF-8)
F() { d="$(mktemp -d)"; n=$'a\nb\r\x01\xff c'; mkdir "$d/$n" 2>/dev/null || { n=$'a\nb\r\x01 c'; mkdir "$d/$n"; }; try cd "$d/$n"; catch :; fi; same "$PWD" "$d/$n" cwd; cd /; rm -rf "$d"; }; assert 0 $'cwd ok' $'' F

# only changed variables are passed back: no change may be missed, whatever the bytes, the locale or nocasematch
F() {
  local i n hex c bad=0
  for i in {1..255}; do printf -v hex %02x "$i"; printf -v c "\\x$hex"; printf -v "bv_$i" 'x%sy' "$c"; done
  bv_256=xy
  # every variable gets the value of the next one, so each value differs in one byte
  try for i in {1..255}; do n="bv_$((i + 1))"; printf -v "bv_$i" %s "${!n}"; done; catch :; fi
  for i in {1..254}; do printf -v hex %02x "$((i + 1))"; printf -v c "\\x$hex"; n="bv_$i"; [ "${!n}" = "x${c}y" ] || bad=$((bad + 1)); done
  [ "$bv_255" = xy ] || bad=$((bad + 1))
  echo "wrong: $bad"; unset "${!bv_@}"
}; assert 0 $'wrong: 0' $'' F
F() {
  local -a from=(abc 'a' $'a\n' '*' abc '?' '[a-z]' $'\xc3\xa9' $'x\xff\x01' 'a\b' '(' '!' -n '' -a 0 ' ' 'a b' "'" '$x' x)
  local -a to=(ABC 'a ' 'a' abc '*' a b $'e\xcc\x81' $'x\xff\x02' 'ab' ')' '=' -z ' ' -o 00 $'\t' 'a  b' '"' '$y' '')
  local i n bad=0
  pa=(); declare -gA pm=()
  for i in "${!from[@]}"; do printf -v "pv_$i" %s "${from[i]}"; pa[i]="${from[i]}"; pm["k$i${from[i]}"]="${from[i]}"; done
  shopt -s nocasematch
  try for i in "${!to[@]}"; do printf -v "pv_$i" %s "${to[i]}"; pa[i]="${to[i]}"; pm["k$i${from[i]}"]="${to[i]}"; done; catch :; fi
  shopt -u nocasematch
  for i in "${!to[@]}"; do
    n="pv_$i"
    [ "${!n}" = "${to[i]}" ] && [ "${pa[i]}" = "${to[i]}" ] && [ "${pm["k$i${from[i]}"]}" = "${to[i]}" ] || { bad=$((bad + 1)); echo "pair $i"; }
  done
  echo "wrong: $bad"; unset pa pm "${!pv_@}"
}; assert 0 $'wrong: 0' $'' F
F() { v=1; e=; try unset v; v=1; e=; unset u; catch :; fi; echo "${v-unset} [${e-unset}] ${u-unset}"; }; assert 0 $'1 [] unset' $'' F
F() { v=5; try declare -gx v; catch :; fi; bash -c 'echo "$v"'; try export -n v; catch :; fi; bash -c 'echo "[${v-}]"'; unset v; }; assert 0 $'5\n[]' $'' F
F() { try alias a.b='echo 1' x@y='echo 2' %%='echo 3'; catch :; fi; try unalias a.b; alias x@y='echo 22'; catch :; fi; alias a.b 2>/dev/null || echo gone; alias x@y %%; unalias x@y %%; }; assert 0 $'gone\nalias x@y=\'echo 22\'\nalias %%=\'echo 3\'' $'' F
F() { arr=(); for i in {1..5000}; do arr[i]="value $i"; done; SECONDS=0; try arr[2500]=changed; catch :; fi; echo "${#arr[@]} ${arr[2500]} ${arr[5000]} $((SECONDS < 30))"; unset arr; }; assert 0 $'5000 changed value 5000 1' $'' F
F() { newf() { echo "$1"; }; try newf() { echo "changed $1"; }; catch :; fi; newf x; declare -F try_internal_run; unset -f newf; }; assert 0 $'changed x\ntry_internal_run' $'' F

# with more than 200 variables their names are listed with a command substitution
F() {
  local i; for i in {1..250}; do printf -v "many_$i" %s "$i"; done
  H() { local h=1; echo err >&2; "$@"; }
  G() { local l=0; try local b=1; l=1; many_7=changed; unset many_9; H false; echo reached; catch echo "error $ERR b=$b l=$l $many_7 ${many_9-unset} $many_250 ${h-unset}"; fi; }
  G 2>/dev/null
  G() { local l=0; try l=1; many_8=changed; H exit 4; echo reached; catcherr echo "error $ERR l=$l $many_8 $(trystderr 2>&1)"; fi; }
  G
  G() { local l=0; try local b=1; try l=1; many_3=inner; throw 5; catch l=2; fi; set -u; : "$many_none"; catch echo "error $ERR l=$l b=${b-unset} $many_3"; fi; }
  G 2>/dev/null
  G() { try local b=2; many_4=x; return 3; catch :; fi; }
  G; echo "rc=$? $many_4"
}; assert 0 $'error 1 b=1 l=1 changed unset 250 unset\nerror 4 l=1 changed err\nerror 1 l=0 b=unset 3\nrc=3 x' $'' F

echo "All tests succeeded"

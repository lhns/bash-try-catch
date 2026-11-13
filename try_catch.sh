if [[ -o posix ]]; then
  # functions can't replace the special builtins exit and trap in POSIX mode
  printf 'try_catch.sh: POSIX mode is not supported\n' >&2
  return 1 2>/dev/null || exit 1
fi
# The library depends on a place where bash doesn't ignore errexit, no matter where the caller is (see
# try_internal_start). That is not documented behavior, so the last resort is tested here: a trap handler in a subshell
# has to run and errexit has to end it, in a command substitution that is the condition of an if.
# Sets TRY_INTERNAL_SIGNAL to the signal for that handler. SIGURG is ignored by default, the others are only used if
# it can't be trapped (signals that are ignored when bash starts can't).
try_internal_selftest() {
  local TRY_INTERNAL_DATA
  for TRY_INTERNAL_SIGNAL in URG USR2 USR1 ALRM; do
    TRY_INTERNAL_DATA="$( (builtin trap 'builtin echo run; builtin set -e; builtin false; builtin echo ignored' "$TRY_INTERNAL_SIGNAL"; builtin kill -s "$TRY_INTERNAL_SIGNAL" "$BASHPID") 2>/dev/null)"
    [[ $TRY_INTERNAL_DATA != run ]] || builtin return 0
    # the handler was run, but errexit didn't end it
    [[ -z $TRY_INTERNAL_DATA ]] || builtin return 1
  done
  # no signal can be trapped: try_internal_start reports that if the handler is needed
  TRY_INTERNAL_SIGNAL=
}
if try_internal_selftest; then :; else
  printf 'try_catch.sh: bash %s is not supported (errexit is ignored in trap handlers)\n' "$BASH_VERSION" >&2
  return 1 2>/dev/null || exit 1
fi
unset -f try_internal_selftest
set -e -o pipefail
shopt -s expand_aliases
throw() { builtin return "${1:-1}"; }
trystderr() {
  local TRY_INTERNAL_I
  for ((TRY_INTERNAL_I = 0; TRY_INTERNAL_I < ${#TRY_INTERNAL_STDERR[@]}; TRY_INTERNAL_I++)); do
    ((TRY_INTERNAL_I == 0)) || builtin printf '\0'
    builtin printf %s "${TRY_INTERNAL_STDERR[TRY_INTERNAL_I]}"
  done >&2
}
TRY_INTERNAL_STDERR=()

# Variables that are not passed back from the try block: the ones that bash sets itself (the variables of the library,
# TRY_INTERNAL_*, are tested separately). BASH_REMATCH is readonly before bash 5.1. The library doesn't use [[ =~ ]]
# outside of the relay, so it doesn't change BASH_REMATCH of the caller or the try block.
declare -gA TRY_INTERNAL_SPECIAL=()
for TRY_INTERNAL_NAME in BASH BASHOPTS BASHPID BASH_ALIASES BASH_ARGC BASH_ARGV BASH_CMDS BASH_COMMAND \
  BASH_EXECUTION_STRING BASH_LINENO BASH_MONOSECONDS BASH_SOURCE BASH_SUBSHELL BASH_TRAPSIG BASH_VERSINFO BASH_VERSION \
  BASH_XTRACEFD PWD OLDPWD RANDOM SRANDOM SECONDS LINENO FUNCNAME GROUPS PIPESTATUS SHLVL _ EPOCHSECONDS EPOCHREALTIME \
  HISTCMD PPID UID EUID DIRSTACK SHELLOPTS COMP_CWORD COMP_KEY COMP_LINE COMP_POINT COMP_TYPE COMP_WORDBREAKS COMP_WORDS \
  COLUMNS LINES ERR; do
  TRY_INTERNAL_SPECIAL[$TRY_INTERNAL_NAME]=1
done
((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))) || TRY_INTERNAL_SPECIAL[BASH_REMATCH]=1
unset TRY_INTERNAL_NAME
# the state before the try block, see try_internal_snapshot
declare -gA TRY_INTERNAL_OLD=() TRY_INTERNAL_OLD_ATTRS=() TRY_INTERNAL_OLD_ALIASES=()
# Code that sets TRY_INTERNAL_NAMES to the names of all variables (evaluated in the scope whose variables are listed).
# "${!prefix@}" needs no subshell, but bash goes through all variables for each of the 53 prefixes: that takes seconds
# with thousands of variables. Then one command substitution with compgen is faster. TRY_INTERNAL_COUNT is the number
# of variables that were listed the last time.
TRY_INTERNAL_LIST_NAMES="TRY_INTERNAL_NAMES=($(printf '"${!%s@}" ' {A..Z} {a..z} _))"
TRY_INTERNAL_COUNT=0
# $1: output of compgen -v, sets TRY_INTERNAL_NAMES
try_internal_names() {
  local IFS=$'\n'
  TRY_INTERNAL_NAMES=($1)
}
# (bash can be built without compgen)
if builtin compgen -v TRY_INTERNAL_LIST_NAMES >/dev/null 2>&1; then
  TRY_INTERNAL_LIST_NAMES="if ((TRY_INTERNAL_COUNT > 200)); then try_internal_names \"\$(builtin compgen -v)\"; else $TRY_INTERNAL_LIST_NAMES; fi; TRY_INTERNAL_COUNT=\${#TRY_INTERNAL_NAMES[@]}"
  try_internal_names "$(builtin compgen -v)"
  TRY_INTERNAL_COUNT=${#TRY_INTERNAL_NAMES[@]}
  unset TRY_INTERNAL_NAMES
fi
# break and continue can't leave a function, so the try block runs inside this many loops that catch them
TRY_INTERNAL_LOOPS=10
# options that are set for the try block by the library and not passed back (xtrace is passed back separately)
TRY_INTERNAL_OWN_OPTIONS=':errexit:errtrace:functrace:pipefail:extdebug:inherit_errexit:xtrace:'

# Code that tests whether a variable is local to the current function. It can't be a function, that would be another
# scope. Since bash 5.1 "local -p NAME" only succeeds for local variables, before that it succeeds for all variables.
try_internal_probe() { builtin local -p TRY_INTERNAL_LOOPS >/dev/null 2>&1; }
if try_internal_probe; then
  # In the caller (%s is the name), in a subshell: a global variable that isn't shadowed by a local one shows the
  # values that are assigned with declare -g.
  TRY_INTERNAL_IS_LOCAL='( builtin declare -g %s=1; TRY_INTERNAL_PROBE="${%s-}"; builtin declare -g %s=2; [[ ${%s-} == "$TRY_INTERNAL_PROBE" ]] ) 2>/dev/null'
  # At the end of the try block (the name is $TRY_INTERNAL_N, the output is discarded): declaring a local variable
  # again keeps its value and attributes, a new local variable is unset. It only shadows the variable of the caller
  # until the block returns.
  TRY_INTERNAL_IS_BLOCK_LOCAL='if [[ -R $TRY_INTERNAL_N ]]; then builtin local -n "$TRY_INTERNAL_N" && [[ -R $TRY_INTERNAL_N ]] && eval "[[ -n \${!$TRY_INTERNAL_N} ]]"; else builtin local "$TRY_INTERNAL_N" && [[ -n ${!TRY_INTERNAL_N+x} || -n ${!TRY_INTERNAL_N@a} ]]; fi'
else
  TRY_INTERNAL_IS_LOCAL='builtin local -p %s >/dev/null 2>&1'
  TRY_INTERNAL_IS_BLOCK_LOCAL='builtin local -p "$TRY_INTERNAL_N"'
fi
unset -f try_internal_probe

# $1: name of a variable, sets TRY_INTERNAL_SER to "<attributes> <code that assigns the value>" or to "" if it is not
# set.
# printf %q is binary safe. declare -p and @A are not and some bash builds (MSYS2) drop \r in compound array
# assignments like a=([0]=$'\r'), so arrays are assigned element by element.
try_internal_ser() {
  local TRY_INTERNAL_KEY TRY_INTERNAL_ATTRS
  TRY_INTERNAL_SER=
  if [[ -R $1 ]]; then
    # a nameref: ${!nameref} is the name of the referenced variable
    eval "TRY_INTERNAL_KEY=\${!$1}"
    builtin printf -v TRY_INTERNAL_SER 'n builtin declare -gn %s=%q' "$1" "$TRY_INTERNAL_KEY"
    builtin return 0
  fi
  # (bash 4.4 crashes on indirect expansions like ${!ref@A} if ref is "array[@]")
  TRY_INTERNAL_ATTRS="${!1@a}"
  if [[ $TRY_INTERNAL_ATTRS == *[aA]* ]]; then
    local -n TRY_INTERNAL_ARRAY="$1"
    local -a TRY_INTERNAL_ITEMS=()
    for TRY_INTERNAL_KEY in "${!TRY_INTERNAL_ARRAY[@]}"; do
      TRY_INTERNAL_ITEMS+=("$1" "$TRY_INTERNAL_KEY" "${TRY_INTERNAL_ARRAY[$TRY_INTERNAL_KEY]}")
    done
    # One printf for all elements (it would print the format once without arguments). One command per line: bash
    # can't run a list of thousands of commands that are separated by ";".
    [[ ${#TRY_INTERNAL_ITEMS[@]} == 0 ]] || builtin printf -v TRY_INTERNAL_SER '\n%s[%q]=%q' "${TRY_INTERNAL_ITEMS[@]}"
    TRY_INTERNAL_SER="$1=()$TRY_INTERNAL_SER"
  elif [[ -n ${!1+x} ]]; then
    builtin printf -v TRY_INTERNAL_SER '%s=%q' "$1" "${!1}"
  else
    builtin return 0
  fi
  TRY_INTERNAL_SER="$TRY_INTERNAL_ATTRS $TRY_INTERNAL_SER"
}

# $1: mode (0: catch, 1: catcherr), rest: positional parameters of the caller
# sets ERR and TRY_INTERNAL_APPLY which has to be evaluated in the scope of the caller
try_internal_run() {
  # the xtrace option of the caller applies to the try block only
  { TRY_INTERNAL_XTRACE=; [[ ! -o xtrace ]] || TRY_INTERNAL_XTRACE=1; builtin set +x; } 2>/dev/null
  # the options are restored by hand, "local -" turns expand_aliases off in bash 4.4
  local TRY_INTERNAL_RESTORE=
  [[ ! -o errexit ]] || TRY_INTERNAL_RESTORE+=e
  [[ ! -o nounset ]] || TRY_INTERNAL_RESTORE+=u
  builtin set +e
  if [[ -o allexport ]]; then
    # the variables of the library are not exported, try_internal_child turns it on again for the try block
    TRY_INTERNAL_RESTORE+=a
    builtin set +a
    builtin export -n TRY_INTERNAL_RESTORE TRY_INTERNAL_XTRACE TRY_INTERNAL_ERR_TRAP
  fi
  try_internal_run_block "$@"
  [[ -z $TRY_INTERNAL_RESTORE ]] || builtin set "-$TRY_INTERNAL_RESTORE"
  [[ -z $TRY_INTERNAL_XTRACE ]] || builtin set -x
}

# the part of try_internal_run that runs without errexit
try_internal_run_block() {
  local TRY_INTERNAL_FD TRY_INTERNAL_DATA TRY_INTERNAL_LINE TRY_INTERNAL_NAME
  local -a TRY_INTERNAL_LINES
  local -A TRY_INTERNAL_FUNC_NAMES=() TRY_INTERNAL_RECORDS=()
  TRY_INTERNAL_STDERR=()
  TRY_INTERNAL_APPLY=
  ERR=0
  if [[ -o posix ]]; then
    builtin printf 'try_catch.sh: POSIX mode is not supported\n' >&2
    ERR=2
    builtin return 0
  fi
  TRY_INTERNAL_CALLER_ERR=
  if [[ -n ${TRY_INTERNAL_PID-} ]]; then
    # inside of a try block (or a subshell of it) the ERR trap is the one of the library, the one of the try block is
    # TRY_INTERNAL_USER_ERR
    TRY_INTERNAL_CALLER_ERR="$TRY_INTERNAL_USER_ERR"
  elif [[ -n $TRY_INTERNAL_ERR_TRAP ]]; then
    # "trap -p ERR" of the caller, if it applies to the try block (see the catch aliases)
    eval "try_internal_trap_action ${TRY_INTERNAL_ERR_TRAP#trap }"
  fi
  exec {TRY_INTERNAL_FD}>&1
  # Bash ignores errexit in everything that runs inside if/while/until conditions and &&/||/! lists, including
  # subshells and functions. A command substitution in the word list of a for loop is not affected by that (see
  # try_internal_start for the exception) and $? is its exit code in the first command of the loop.
  # The results are written to the pipe of the command substitution (by try_internal_relay), the stdout of the
  # subshell is the one of the caller.
  for TRY_INTERNAL_DATA in "$(exec {TRY_INTERNAL_OUT}>&1 >&"$TRY_INTERNAL_FD" {TRY_INTERNAL_FD}>&-; try_internal_start "$@")"; do
    ERR=$?
  done
  exec {TRY_INTERNAL_FD}>&-
  builtin unset -f TRY_INTERNAL_F
  # only after the subshell was started, the try block uses the IFS of the caller
  local IFS=$' \t\n'
  builtin set +u

  # nothing is passed back if the subshell was killed
  try_internal_records || builtin return 0
  if [[ $1 == 1 ]]; then
    try_internal_lines "${TRY_INTERNAL_RECORDS[S]}"
    # one line per NUL separated part of stderr, quoted with printf %q
    for TRY_INTERNAL_LINE in "${TRY_INTERNAL_LINES[@]}"; do
      eval "TRY_INTERNAL_STDERR[\${#TRY_INTERNAL_STDERR[@]}]=$TRY_INTERNAL_LINE"
    done
  fi
  TRY_INTERNAL_APPLY="${TRY_INTERNAL_RECORDS[C]}"
  TRY_INTERNAL_COUNT="${TRY_INTERNAL_RECORDS[K]:-0}"

  # functions: T is "=" if no function was changed, otherwise the output of declare -f
  [[ ${TRY_INTERNAL_RECORDS[T]} == = ]] && builtin return 0
  eval -- "${TRY_INTERNAL_RECORDS[T]}" 2>/dev/null
  # declare -F prints one "declare -f[attributes] name" line per function
  try_internal_lines "${TRY_INTERNAL_RECORDS[N]}"
  for TRY_INTERNAL_LINE in "${TRY_INTERNAL_LINES[@]}"; do
    TRY_INTERNAL_NAME="${TRY_INTERNAL_LINE#declare -* }"
    TRY_INTERNAL_FUNC_NAMES[$TRY_INTERNAL_NAME]=1
    TRY_INTERNAL_LINE="${TRY_INTERNAL_LINE#declare -f}"
    TRY_INTERNAL_LINE="${TRY_INTERNAL_LINE%% *}"
    [[ $TRY_INTERNAL_LINE != *x* ]] || builtin export -f -- "$TRY_INTERNAL_NAME"
    [[ $TRY_INTERNAL_LINE != *t* ]] || builtin declare -ft -- "$TRY_INTERNAL_NAME"
  done
  # functions that were unset in the try block
  try_internal_lines "${TRY_INTERNAL_RECORDS[B]}"
  for TRY_INTERNAL_LINE in "${TRY_INTERNAL_LINES[@]}"; do
    TRY_INTERNAL_NAME="${TRY_INTERNAL_LINE#declare -* }"
    [[ -n ${TRY_INTERNAL_FUNC_NAMES[$TRY_INTERNAL_NAME]} ]] || builtin unset -f -- "$TRY_INTERNAL_NAME"
  done
}

# Splits the output of the relay (TRY_INTERNAL_DATA) into TRY_INTERNAL_RECORDS. Records are
# "<kind> <length in bytes>\n<data>" and are cut by offset, searching patterns in large strings is quadratic in bash.
# Fails if the last record (E) is missing.
try_internal_records() {
  local LC_ALL=C TRY_INTERNAL_POS=0 TRY_INTERNAL_HEAD TRY_INTERNAL_KIND TRY_INTERNAL_LEN
  while ((TRY_INTERNAL_POS < ${#TRY_INTERNAL_DATA})); do
    TRY_INTERNAL_HEAD="${TRY_INTERNAL_DATA:TRY_INTERNAL_POS:32}"
    # the command substitution removed the newline after the last record
    [[ $TRY_INTERNAL_HEAD != 'E 0' ]] || builtin return 0
    [[ $TRY_INTERNAL_HEAD == ?' '*$'\n'* ]] || builtin return 1
    TRY_INTERNAL_HEAD="${TRY_INTERNAL_HEAD%%$'\n'*}"
    TRY_INTERNAL_KIND="${TRY_INTERNAL_HEAD%% *}"
    TRY_INTERNAL_LEN="${TRY_INTERNAL_HEAD#* }"
    [[ -n $TRY_INTERNAL_LEN && $TRY_INTERNAL_LEN != *[!0-9]* ]] || builtin return 1
    [[ $TRY_INTERNAL_KIND != E ]] || builtin return 0
    TRY_INTERNAL_POS=$((TRY_INTERNAL_POS + ${#TRY_INTERNAL_HEAD} + 1))
    TRY_INTERNAL_RECORDS[$TRY_INTERNAL_KIND]="${TRY_INTERNAL_DATA:TRY_INTERNAL_POS:TRY_INTERNAL_LEN}"
    TRY_INTERNAL_POS=$((TRY_INTERNAL_POS + TRY_INTERNAL_LEN))
  done
  builtin return 1
}

# $1: kind, $2: data, $3: file descriptor, writes a record "<kind> <length in bytes>\n<data>"
try_internal_send() {
  local LC_ALL=C
  builtin printf '%s %s\n%s' "$1" "${#2}" "$2" >&"$3"
}

# $1: text, splits it into the non-empty lines TRY_INTERNAL_LINES
try_internal_lines() {
  local IFS=$'\n' TRY_INTERNAL_GLOB=
  [[ -o noglob ]] || TRY_INTERNAL_GLOB=1
  builtin set -f
  TRY_INTERNAL_LINES=($1)
  [[ -z $TRY_INTERNAL_GLOB ]] || builtin set +f
}

# prints the state that can only be printed: umask, soft limits, hard limits, declare -F and declare -f
# separated by lines "#". The first lines are labels, so no part is empty.
# Runs in a command substitution, so the functions of the library can be removed: they are not compared and passed back.
try_internal_state() {
  builtin unset -f TRY_INTERNAL_F "${TRY_INTERNAL_FUNCTIONS[@]}"
  builtin echo U
  builtin umask -p
  builtin echo '#'
  builtin echo S
  builtin ulimit -S -a 2>/dev/null
  builtin echo '#'
  builtin echo H
  builtin ulimit -H -a 2>/dev/null
  builtin echo '#'
  builtin declare -F
  builtin echo '#'
  builtin declare -f
}

# $1: output of try_internal_state, splits it into TRY_INTERNAL_PARTS (umask, soft limits, hard limits, declare -F,
# declare -f). The first four parts have no empty lines, so the offset of the last part is the sum of the line lengths.
try_internal_parts() {
  local LC_ALL=C TRY_INTERNAL_LINE TRY_INTERNAL_PART= TRY_INTERNAL_OFFSET=0
  local -a TRY_INTERNAL_LINES
  TRY_INTERNAL_PARTS=()
  try_internal_lines "$1"
  for TRY_INTERNAL_LINE in "${TRY_INTERNAL_LINES[@]}"; do
    TRY_INTERNAL_OFFSET=$((TRY_INTERNAL_OFFSET + ${#TRY_INTERNAL_LINE} + 1))
    if [[ $TRY_INTERNAL_LINE == '#' ]]; then
      TRY_INTERNAL_PARTS+=("${TRY_INTERNAL_PART%$'\n'}")
      TRY_INTERNAL_PART=
      ((${#TRY_INTERNAL_PARTS[@]} < 4)) || break
    else
      TRY_INTERNAL_PART+="$TRY_INTERNAL_LINE"$'\n'
    fi
  done
  TRY_INTERNAL_PARTS+=("${1:TRY_INTERNAL_OFFSET}")
}

# $1: soft or hard (-S or -H), $2: "ulimit -a" before, $3: after, appends ulimit commands to TRY_INTERNAL_CODE
try_internal_limits() {
  local TRY_INTERNAL_LINE
  local -A TRY_INTERNAL_OLD=()
  try_internal_lines "$2"
  for TRY_INTERNAL_LINE in "${TRY_INTERNAL_LINES[@]}"; do
    [[ ! $TRY_INTERNAL_LINE =~ -([a-zA-Z])\)\ +([^ ]+)$ ]] || TRY_INTERNAL_OLD[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
  done
  try_internal_lines "$3"
  for TRY_INTERNAL_LINE in "${TRY_INTERNAL_LINES[@]}"; do
    if [[ $TRY_INTERNAL_LINE =~ -([a-zA-Z])\)\ +([^ ]+)$ && ${TRY_INTERNAL_OLD[${BASH_REMATCH[1]}]} != "${BASH_REMATCH[2]}" ]]; then
      TRY_INTERNAL_CODE+="builtin ulimit $1 -${BASH_REMATCH[1]} ${BASH_REMATCH[2]} 2>/dev/null"$'\n'
    fi
  done
}

# $1: attributes, sets TRY_INTERNAL_TYPE to the kind of variable: A (associative array), a (indexed array), n (nameref)
# or s (scalar)
try_internal_type() {
  case "$1" in
    *A*) TRY_INTERNAL_TYPE=A ;;
    *a*) TRY_INTERNAL_TYPE=a ;;
    *n*) TRY_INTERNAL_TYPE=n ;;
    *) TRY_INTERNAL_TYPE=s ;;
  esac
}

# $1: name of a variable, $2: options for declare, appends the declare command for the variable of the caller to
# TRY_INTERNAL_CODE. Without -g it would create a local variable if the caller doesn't have one.
try_internal_declare() {
  TRY_INTERNAL_CODE+="if ${TRY_INTERNAL_IS_LOCAL//%s/$1}; then builtin declare $2 $1; else builtin declare -g $2 $1; fi"$'\n'
}

# Without arguments: keeps a copy of all variables that can be passed back in TRY_INTERNAL_OLD (the value, for arrays
# and namerefs the code from try_internal_ser) and TRY_INTERNAL_OLD_ATTRS ("=<attributes>", "=n" for a nameref).
# With "diff": compares the variables with that copy and appends the code for the changed ones to TRY_INTERNAL_CODE.
# So only the variables that the try block changed are quoted and passed back.
# Values are compared with [ = ], which compares bytes: [[ == ]] depends on the locale and on nocasematch.
try_internal_vars() {
  local TRY_INTERNAL_NAME TRY_INTERNAL_ATTRS TRY_INTERNAL_VALUE TRY_INTERNAL_SER TRY_INTERNAL_OLD_A TRY_INTERNAL_FLAG \
    TRY_INTERNAL_ADD TRY_INTERNAL_REMOVE TRY_INTERNAL_TYPE TRY_INTERNAL_OLD_TYPE
  local -a TRY_INTERNAL_NAMES
  eval "$TRY_INTERNAL_LIST_NAMES"
  for TRY_INTERNAL_NAME in "${TRY_INTERNAL_NAMES[@]}"; do
    [[ -z ${TRY_INTERNAL_SPECIAL[$TRY_INTERNAL_NAME]+x} && $TRY_INTERNAL_NAME != TRY_INTERNAL_* ]] || continue
    if [[ -R $TRY_INTERNAL_NAME ]]; then
      TRY_INTERNAL_ATTRS=n
    else
      TRY_INTERNAL_ATTRS="${!TRY_INTERNAL_NAME@a}"
    fi
    if [[ $TRY_INTERNAL_ATTRS == *[aAn]* ]]; then
      try_internal_ser "$TRY_INTERNAL_NAME"
      TRY_INTERNAL_VALUE="${TRY_INTERNAL_SER#* }"
    else
      TRY_INTERNAL_VALUE="${!TRY_INTERNAL_NAME}"
    fi
    if [[ -z ${1-} ]]; then
      TRY_INTERNAL_OLD[$TRY_INTERNAL_NAME]="$TRY_INTERNAL_VALUE"
      TRY_INTERNAL_OLD_ATTRS[$TRY_INTERNAL_NAME]="=$TRY_INTERNAL_ATTRS"
      continue
    fi

    TRY_INTERNAL_OLD_A="${TRY_INTERNAL_OLD_ATTRS[$TRY_INTERNAL_NAME]-}"
    # the names that are left in the end are the variables that were unset in the try block
    builtin unset "TRY_INTERNAL_OLD_ATTRS[$TRY_INTERNAL_NAME]"
    [[ "=$TRY_INTERNAL_ATTRS" != "$TRY_INTERNAL_OLD_A" ]] ||
      ! builtin [ "$TRY_INTERNAL_VALUE" = "${TRY_INTERNAL_OLD[$TRY_INTERNAL_NAME]}" ] || continue
    # readonly variables can't be changed
    [[ $TRY_INTERNAL_OLD_A != *r* ]] || continue
    if [[ $TRY_INTERNAL_ATTRS == *[aAn]* ]]; then
      TRY_INTERNAL_SER="$TRY_INTERNAL_VALUE"
    else
      builtin printf -v TRY_INTERNAL_SER '%s=%q' "$TRY_INTERNAL_NAME" "$TRY_INTERNAL_VALUE"
    fi
    try_internal_type "$TRY_INTERNAL_OLD_A"
    TRY_INTERNAL_OLD_TYPE=$TRY_INTERNAL_TYPE
    try_internal_type "$TRY_INTERNAL_ATTRS"
    if [[ -n $TRY_INTERNAL_OLD_A && $TRY_INTERNAL_TYPE != "$TRY_INTERNAL_OLD_TYPE" ]]; then
      # an assignment can't change the kind of a variable (unset keeps a local variable of the caller local)
      TRY_INTERNAL_CODE+="builtin unset -v $TRY_INTERNAL_NAME"$'\n'
      TRY_INTERNAL_OLD_A=
    fi
    # associative arrays have to be declared
    [[ $TRY_INTERNAL_TYPE != A || $TRY_INTERNAL_OLD_TYPE == A ]] || try_internal_declare "$TRY_INTERNAL_NAME" -A
    TRY_INTERNAL_ADD= TRY_INTERNAL_REMOVE=
    for TRY_INTERNAL_FLAG in i l u; do
      [[ $TRY_INTERNAL_ATTRS != *$TRY_INTERNAL_FLAG* || $TRY_INTERNAL_OLD_A == *$TRY_INTERNAL_FLAG* ]] || TRY_INTERNAL_ADD+=$TRY_INTERNAL_FLAG
      [[ $TRY_INTERNAL_ATTRS == *$TRY_INTERNAL_FLAG* || $TRY_INTERNAL_OLD_A != *$TRY_INTERNAL_FLAG* ]] || TRY_INTERNAL_REMOVE+=$TRY_INTERNAL_FLAG
    done
    # attributes are removed before and added after the assignment, so they don't change the value
    [[ -z $TRY_INTERNAL_REMOVE ]] || try_internal_declare "$TRY_INTERNAL_NAME" "+$TRY_INTERNAL_REMOVE"
    # plain assignments respect dynamic scoping: globals stay global and locals of the caller stay local
    TRY_INTERNAL_CODE+="$TRY_INTERNAL_SER"$'\n'
    [[ -z $TRY_INTERNAL_ADD ]] || try_internal_declare "$TRY_INTERNAL_NAME" "-$TRY_INTERNAL_ADD"
    [[ $TRY_INTERNAL_ATTRS != *x* || $TRY_INTERNAL_OLD_A == *x* ]] || TRY_INTERNAL_CODE+="builtin export $TRY_INTERNAL_NAME"$'\n'
    [[ $TRY_INTERNAL_ATTRS == *x* || $TRY_INTERNAL_OLD_A != *x* ]] || TRY_INTERNAL_CODE+="builtin export -n $TRY_INTERNAL_NAME"$'\n'
    [[ $TRY_INTERNAL_ATTRS != *r* ]] || TRY_INTERNAL_CODE+="builtin readonly $TRY_INTERNAL_NAME"$'\n'
  done
  [[ -n ${1-} ]] || builtin return 0
  for TRY_INTERNAL_NAME in "${!TRY_INTERNAL_OLD_ATTRS[@]}"; do
    TRY_INTERNAL_CODE+="builtin unset -v $TRY_INTERNAL_NAME"$'\n'
  done
}

# Keeps a copy of the variables, aliases and the directory stack before the try block, see try_internal_diff
try_internal_snapshot() {
  local TRY_INTERNAL_NAME
  TRY_INTERNAL_OLD=() TRY_INTERNAL_OLD_ATTRS=() TRY_INTERNAL_OLD_ALIASES=() TRY_INTERNAL_OLD_DIRS=("${DIRSTACK[@]}")
  try_internal_vars
  for TRY_INTERNAL_NAME in "${!BASH_ALIASES[@]}"; do
    TRY_INTERNAL_OLD_ALIASES[$TRY_INTERNAL_NAME]="${BASH_ALIASES[$TRY_INTERNAL_NAME]}"
  done
}

# $1: "novars" if the variable scopes are gone. Appends the code that repeats what the try block changed (compared to
# try_internal_snapshot) to TRY_INTERNAL_CODE: variables, aliases and the directory stack.
try_internal_diff() {
  local TRY_INTERNAL_NAME TRY_INTERNAL_SER TRY_INTERNAL_FLAG= TRY_INTERNAL_I
  [[ $1 == novars ]] || try_internal_vars diff
  for TRY_INTERNAL_NAME in "${!BASH_ALIASES[@]}"; do
    if [[ -z ${TRY_INTERNAL_OLD_ALIASES[$TRY_INTERNAL_NAME]+x} ]] ||
      ! builtin [ "${TRY_INTERNAL_OLD_ALIASES[$TRY_INTERNAL_NAME]}" = "${BASH_ALIASES[$TRY_INTERNAL_NAME]}" ]; then
      builtin printf -v TRY_INTERNAL_SER 'BASH_ALIASES[%q]=%q' "$TRY_INTERNAL_NAME" "${BASH_ALIASES[$TRY_INTERNAL_NAME]}"
      TRY_INTERNAL_CODE+="$TRY_INTERNAL_SER"$'\n'
    fi
  done
  for TRY_INTERNAL_NAME in "${!TRY_INTERNAL_OLD_ALIASES[@]}"; do
    if [[ -z ${BASH_ALIASES[$TRY_INTERNAL_NAME]+x} ]]; then
      builtin printf -v TRY_INTERNAL_SER 'builtin unalias -- %q' "$TRY_INTERNAL_NAME"
      TRY_INTERNAL_CODE+="$TRY_INTERNAL_SER"$'\n'
    fi
  done
  # DIRSTACK[0] is the working directory, the rest is rebuilt with pushd -n if it was changed
  [[ ${#DIRSTACK[@]} == "${#TRY_INTERNAL_OLD_DIRS[@]}" ]] || TRY_INTERNAL_FLAG=1
  for ((TRY_INTERNAL_I = 1; TRY_INTERNAL_I < ${#DIRSTACK[@]}; TRY_INTERNAL_I++)); do
    builtin [ "${DIRSTACK[TRY_INTERNAL_I]}" = "${TRY_INTERNAL_OLD_DIRS[TRY_INTERNAL_I]-}" ] || TRY_INTERNAL_FLAG=1
  done
  if [[ -n $TRY_INTERNAL_FLAG ]]; then
    TRY_INTERNAL_CODE+="builtin dirs -c"$'\n'
    for ((TRY_INTERNAL_I = ${#DIRSTACK[@]} - 1; TRY_INTERNAL_I >= 1; TRY_INTERNAL_I--)); do
      builtin printf -v TRY_INTERNAL_SER 'builtin pushd -n -- %q >/dev/null' "${DIRSTACK[TRY_INTERNAL_I]}"
      TRY_INTERNAL_CODE+="$TRY_INTERNAL_SER"$'\n'
    done
  fi
}

# Holds the pipe of the command substitution and copies the results of the subshell to it. The subshell itself
# closes the pipe, so that background jobs started in the try block can't keep it open. Messages are records (see
# try_internal_records), so no end of file is needed (background jobs may keep the other pipe open).
# The relay is forked when the subshell starts, so it prints the state that can only be printed (try_internal_state)
# before the try block, while the try block runs, and compares it with the state after it.
try_internal_relay() {
  { builtin set +xu; } 2>/dev/null
  builtin shopt -u nocasematch
  local TRY_INTERNAL_KIND TRY_INTERNAL_LEN TRY_INTERNAL_DATA TRY_INTERNAL_CODE= TRY_INTERNAL_CHILD_CODE= \
    TRY_INTERNAL_JUMP_CODE= TRY_INTERNAL_NAMES_BEFORE= TRY_INTERNAL_NAMES_OUT= TRY_INTERNAL_TEXT_OUT== TRY_INTERNAL_STATE_TEXT
  local -a TRY_INTERNAL_LINES TRY_INTERNAL_PARTS TRY_INTERNAL_STATE
  TRY_INTERNAL_STATE_TEXT="$(try_internal_state)"
  local IFS=$' \t\n' LC_ALL=C

  while builtin read -r TRY_INTERNAL_KIND TRY_INTERNAL_LEN; do
    TRY_INTERNAL_DATA=
    if [[ $TRY_INTERNAL_LEN != 0 ]]; then
      IFS= builtin read -r -N "$TRY_INTERNAL_LEN" TRY_INTERNAL_DATA || break
    fi
    case "$TRY_INTERNAL_KIND" in
      # stderr for catcherr and the number of variables are passed on
      S | K) try_internal_send "$TRY_INTERNAL_KIND" "$TRY_INTERNAL_DATA" "$TRY_INTERNAL_OUT" ;;
      # code from the subshell: variables, aliases, working directory, options, traps, positional parameters
      C) TRY_INTERNAL_CHILD_CODE="$TRY_INTERNAL_DATA" ;;
      # return, break or continue
      J) TRY_INTERNAL_JUMP_CODE="$TRY_INTERNAL_DATA" ;;
      # output of try_internal_state after the try block, usually the same as before
      X)
        if ! builtin [ "$TRY_INTERNAL_DATA" = "$TRY_INTERNAL_STATE_TEXT" ]; then
          try_internal_parts "$TRY_INTERNAL_STATE_TEXT"
          TRY_INTERNAL_STATE=("${TRY_INTERNAL_PARTS[@]}")
          try_internal_parts "$TRY_INTERNAL_DATA"
          # umask
          [[ ${TRY_INTERNAL_PARTS[0]} == "${TRY_INTERNAL_STATE[0]}" ]] || TRY_INTERNAL_CODE+="builtin ${TRY_INTERNAL_PARTS[0]#U$'\n'}"$'\n'
          # hard limits first, a lower hard limit also lowers the soft limit
          try_internal_limits -H "${TRY_INTERNAL_STATE[2]}" "${TRY_INTERNAL_PARTS[2]}"
          try_internal_limits -S "${TRY_INTERNAL_STATE[1]}" "${TRY_INTERNAL_PARTS[1]}"
          # functions
          if ! builtin [ "${TRY_INTERNAL_PARTS[3]}"$'\n'"${TRY_INTERNAL_PARTS[4]}" = "${TRY_INTERNAL_STATE[3]}"$'\n'"${TRY_INTERNAL_STATE[4]}" ]; then
            TRY_INTERNAL_NAMES_BEFORE="${TRY_INTERNAL_STATE[3]}"
            TRY_INTERNAL_NAMES_OUT="${TRY_INTERNAL_PARTS[3]}"
            TRY_INTERNAL_TEXT_OUT="${TRY_INTERNAL_PARTS[4]}"
          fi
        fi
        ;;
      E)
        try_internal_send C "$TRY_INTERNAL_CODE$TRY_INTERNAL_CHILD_CODE$TRY_INTERNAL_JUMP_CODE" "$TRY_INTERNAL_OUT"
        # functions: the names before and after the try block and the text after it, "=" if nothing was changed
        try_internal_send B "$TRY_INTERNAL_NAMES_BEFORE" "$TRY_INTERNAL_OUT"
        try_internal_send N "$TRY_INTERNAL_NAMES_OUT" "$TRY_INTERNAL_OUT"
        try_internal_send T "$TRY_INTERNAL_TEXT_OUT" "$TRY_INTERNAL_OUT"
        try_internal_send E "" "$TRY_INTERNAL_OUT"
        break
        ;;
    esac
  done
}

# $1: the value of SHELLOPTS or BASHOPTS before the try block, $2: after, $3: command to set, $4: command to unset
# appends the commands for the options that were changed in the try block to TRY_INTERNAL_CODE
try_internal_options() {
  local TRY_INTERNAL_OPTION
  local IFS=:
  for TRY_INTERNAL_OPTION in $2; do
    [[ :$1: == *:$TRY_INTERNAL_OPTION:* || $TRY_INTERNAL_OWN_OPTIONS == *:$TRY_INTERNAL_OPTION:* ]] ||
      TRY_INTERNAL_CODE+="$3 $TRY_INTERNAL_OPTION"$'\n'
  done
  for TRY_INTERNAL_OPTION in $1; do
    [[ :$2: == *:$TRY_INTERNAL_OPTION:* || $TRY_INTERNAL_OWN_OPTIONS == *:$TRY_INTERNAL_OPTION:* ]] ||
      TRY_INTERNAL_CODE+="$4 $TRY_INTERNAL_OPTION"$'\n'
  done
}

# Turns off xtrace when the try block ends and records whether it was on (only the first call counts).
# Called as "{ try_internal_xtrace_off; } 2>/dev/null", so the call itself isn't traced either.
try_internal_xtrace_off() {
  if [[ -z $TRY_INTERNAL_XTRACE_END ]]; then
    TRY_INTERNAL_XTRACE_END=0
    [[ ! -o xtrace ]] || TRY_INTERNAL_XTRACE_END=1
  fi
  builtin set +x
}

# Evaluated in the try block function when it is done (end, error, exit): positional parameters and local variables.
# The options nocasematch and localvar_inherit of the try block would change the tests.
TRY_INTERNAL_BLOCK_END='TRY_INTERNAL_ARGS=("$@"); TRY_INTERNAL_HAVE_ARGS=1; eval "$TRY_INTERNAL_LIST_NAMES"; TRY_INTERNAL_BLOCK_LOCALS=(); TRY_INTERNAL_SHOPTS=(); for TRY_INTERNAL_N in nocasematch localvar_inherit; do ! builtin shopt -q "$TRY_INTERNAL_N" 2>/dev/null || { TRY_INTERNAL_SHOPTS+=("$TRY_INTERNAL_N"); builtin shopt -u "$TRY_INTERNAL_N"; }; done; for TRY_INTERNAL_N in "${TRY_INTERNAL_NAMES[@]}"; do [[ -z ${TRY_INTERNAL_SPECIAL[$TRY_INTERNAL_N]+x} && $TRY_INTERNAL_N != TRY_INTERNAL_* ]] || continue; if '"$TRY_INTERNAL_IS_BLOCK_LOCAL"'; then TRY_INTERNAL_BLOCK_LOCALS+=("$TRY_INTERNAL_N"); fi; done >/dev/null 2>&1; try_internal_block_locals; [[ ${#TRY_INTERNAL_SHOPTS[@]} == 0 ]] || builtin shopt -s "${TRY_INTERNAL_SHOPTS[@]}"'

# called by TRY_INTERNAL_BLOCK_END, sets TRY_INTERNAL_LOCALS_CODE that declares the local variables of the try block
# as local variables of the caller. Outside of functions local fails, then they are global (like declare there).
try_internal_block_locals() {
  local TRY_INTERNAL_NAME TRY_INTERNAL_ATTRS TRY_INTERNAL_SER TRY_INTERNAL_TARGET
  TRY_INTERNAL_LOCALS_CODE=
  for TRY_INTERNAL_NAME in "${TRY_INTERNAL_BLOCK_LOCALS[@]}"; do
    if [[ -R $TRY_INTERNAL_NAME ]]; then
      # ${!nameref} is the name of the referenced variable
      eval "TRY_INTERNAL_TARGET=\${!$TRY_INTERNAL_NAME}"
      builtin printf -v TRY_INTERNAL_SER 'if { builtin local -n %s=%q; } 2>/dev/null; then :; else builtin unset -v %s; builtin declare -gn %s=%q; fi' \
        "$TRY_INTERNAL_NAME" "$TRY_INTERNAL_TARGET" "$TRY_INTERNAL_NAME" "$TRY_INTERNAL_NAME" "$TRY_INTERNAL_TARGET"
      TRY_INTERNAL_LOCALS_CODE+="$TRY_INTERNAL_SER"$'\n'
      continue
    fi
    TRY_INTERNAL_ATTRS="${!TRY_INTERNAL_NAME@a}"
    TRY_INTERNAL_ATTRS="${TRY_INTERNAL_ATTRS//[rxt]/}"
    try_internal_ser "$TRY_INTERNAL_NAME"
    [[ -n $TRY_INTERNAL_SER ]] || continue
    TRY_INTERNAL_LOCALS_CODE+="if { builtin local ${TRY_INTERNAL_ATTRS:+-$TRY_INTERNAL_ATTRS }$TRY_INTERNAL_NAME; } 2>/dev/null; then :; else builtin unset -v $TRY_INTERNAL_NAME; builtin declare -g ${TRY_INTERNAL_ATTRS:+-$TRY_INTERNAL_ATTRS }$TRY_INTERNAL_NAME; fi"$'\n'"${TRY_INTERNAL_SER#* }"$'\n'
    [[ ${TRY_INTERNAL_SER%% *} != *x* ]] || TRY_INTERNAL_LOCALS_CODE+="builtin export $TRY_INTERNAL_NAME"$'\n'
    [[ ${TRY_INTERNAL_SER%% *} != *r* ]] || TRY_INTERNAL_LOCALS_CODE+="builtin readonly $TRY_INTERNAL_NAME"$'\n'
  done
  builtin return 0
}

# $1: name of a variable with a file descriptor, moves it to a free descriptor between 100 and 254, so that code in the
# try block that uses fixed descriptors (e.g. exec 10>file) doesn't replace it. Keeps it if /dev/fd is not available.
try_internal_high_fd() {
  local TRY_INTERNAL_I
  [[ -d /dev/fd ]] || builtin return 0
  for ((TRY_INTERNAL_I = 254; TRY_INTERNAL_I >= 100; TRY_INTERNAL_I--)); do
    if [[ ! -e /dev/fd/$TRY_INTERNAL_I && ! -L /dev/fd/$TRY_INTERNAL_I ]]; then
      eval "exec $TRY_INTERNAL_I>&${!1}" 2>/dev/null || builtin return 0
      eval "exec ${!1}>&-"
      builtin printf -v "$1" %s "$TRY_INTERNAL_I"
      builtin return 0
    fi
  done
}

# Runs in the subshell and starts try_internal_child where errexit is not ignored. The ERR trap tells: bash doesn't run
# it for commands whose failure it ignores. Errexit is still ignored here if the caller is (part of) a command
# substitution in a simple command whose failure is ignored, like "if x=$(f)" or "x=$(f) || ...". Then bash ignores it
# in every command, command substitution and trap handler of that process. A trap handler in another subshell is not
# affected, so the try block runs in the handler of a signal (see try_internal_selftest).
try_internal_start() {
  local TRY_INTERNAL_ERREXIT=
  builtin trap 'TRY_INTERNAL_ERREXIT=1' ERR
  builtin false
  builtin trap - ERR
  [[ -z $TRY_INTERNAL_ERREXIT ]] || try_internal_child "$@"
  TRY_INTERNAL_START_ARGS=("$@")
  (
    if [[ -n $TRY_INTERNAL_SIGNAL ]]; then
      builtin trap 'builtin trap - "$TRY_INTERNAL_SIGNAL"; try_internal_child "${TRY_INTERNAL_START_ARGS[@]}"' "$TRY_INTERNAL_SIGNAL"
      builtin kill -s "$TRY_INTERNAL_SIGNAL" "$BASHPID"
    fi
    # only reached if the handler was not run
    builtin printf 'try_catch.sh: errors can not be caught here, no signal can be trapped\n' >&2
    builtin exit 2
  )
  builtin exit "$?"
}

# runs the try block and sends the changes to try_internal_relay when it is done, exits the subshell
try_internal_child() {
  local TRY_INTERNAL_NAME
  local -a TRY_INTERNAL_NAMES
  TRY_INTERNAL_PID="$BASHPID" TRY_INTERNAL_USER_EXIT= TRY_INTERNAL_UNWINDING= TRY_INTERNAL_DUMPED= TRY_INTERNAL_XTRACE_END=
  TRY_INTERNAL_RETURN_DEPTH= TRY_INTERNAL_EXIT= TRY_INTERNAL_JUMP= TRY_INTERNAL_READER= TRY_INTERNAL_F_DEPTH=$((${#FUNCNAME[@]} + 1))
  TRY_INTERNAL_HAVE_ARGS= TRY_INTERNAL_LOCALS_CODE= TRY_INTERNAL_BEFORE_PWD="$PWD" TRY_INTERNAL_BEFORE_OLDPWD="${OLDPWD-}"
  TRY_INTERNAL_SAVED_FUNCS= TRY_INTERNAL_XTRACE_BEFORE="$TRY_INTERNAL_XTRACE"
  TRY_INTERNAL_USER_TRAPS=()
  # the ERR trap of the caller if it applies to the try block (see try_internal_run)
  TRY_INTERNAL_USER_ERR="$TRY_INTERNAL_CALLER_ERR"
  # only the relay keeps the pipe of the command substitution open
  exec {TRY_INTERNAL_TO_RELAY}> >(try_internal_relay) {TRY_INTERNAL_OUT}>&-
  TRY_INTERNAL_RELAY_PID=$!
  try_internal_high_fd TRY_INTERNAL_TO_RELAY
  # The jobs of the caller are not children of the subshell: with them in the job table, wait would never return.
  builtin disown -a
  # functions of the caller that are replaced in the try block
  for TRY_INTERNAL_NAME in trap exit wait; do
    if builtin declare -F "$TRY_INTERNAL_NAME" >/dev/null; then
      TRY_INTERNAL_SAVED_FUNCS+="$(builtin declare -f "$TRY_INTERNAL_NAME")"$'\n'
    fi
  done
  # EXIT and ERR traps set in the try block must not replace ours, other traps are passed back
  trap() {
    local TRY_INTERNAL_ACTION TRY_INTERNAL_SIG TRY_INTERNAL_SIGS=() TRY_INTERNAL_I
    # subshells of the try block have their own traps
    if [[ $BASHPID != "$TRY_INTERNAL_PID" || ${1-} == -l ]]; then
      builtin trap "$@"
      builtin return
    fi
    if [[ $# == 0 || $1 == -p ]]; then
      [[ $# == 0 ]] || builtin shift
      [[ ${1-} != -- ]] || builtin shift
      # the traps of the try block, not the ones of the library
      if [[ $# == 0 ]]; then
        builtin set -- EXIT ERR DEBUG RETURN
        for ((TRY_INTERNAL_I = 1; TRY_INTERNAL_I <= 64; TRY_INTERNAL_I++)); do builtin set -- "$@" "$TRY_INTERNAL_I"; done
      fi
      for TRY_INTERNAL_SIG in "$@"; do
        case "$TRY_INTERNAL_SIG" in
          EXIT | SIGEXIT | 0) [[ -z $TRY_INTERNAL_USER_EXIT ]] || builtin printf 'trap -- %q EXIT\n' "$TRY_INTERNAL_USER_EXIT" ;;
          ERR | SIGERR) [[ -z $TRY_INTERNAL_USER_ERR ]] || builtin printf 'trap -- %q ERR\n' "$TRY_INTERNAL_USER_ERR" ;;
          *) builtin trap -p "$TRY_INTERNAL_SIG" 2>/dev/null ;;
        esac
      done
      builtin return 0
    fi
    [[ ${1-} != -- ]] || builtin shift
    if [[ $# == 1 ]]; then
      TRY_INTERNAL_ACTION=-
    else
      TRY_INTERNAL_ACTION="$1"
      builtin shift
    fi
    for TRY_INTERNAL_SIG in "$@"; do
      case "$TRY_INTERNAL_SIG" in
        EXIT | SIGEXIT | 0) TRY_INTERNAL_USER_EXIT="$TRY_INTERNAL_ACTION" ;;
        ERR | SIGERR) TRY_INTERNAL_USER_ERR="$TRY_INTERNAL_ACTION" ;;
        *)
          TRY_INTERNAL_SIGS+=("$TRY_INTERNAL_SIG")
          TRY_INTERNAL_USER_TRAPS+=("$TRY_INTERNAL_ACTION" "$TRY_INTERNAL_SIG")
          ;;
      esac
    done
    # "-" resets a trap
    [[ $TRY_INTERNAL_USER_EXIT != - ]] || TRY_INTERNAL_USER_EXIT=
    [[ $TRY_INTERNAL_USER_ERR != - ]] || TRY_INTERNAL_USER_ERR=
    if [[ ${#TRY_INTERNAL_SIGS[@]} != 0 ]]; then
      builtin trap -- "$TRY_INTERNAL_ACTION" "${TRY_INTERNAL_SIGS[@]}"
    fi
  }
  # exit returns from one function after another (extdebug: a DEBUG trap that returns 2 simulates return) until the
  # try block itself returned, so the variables are passed back from the scope of the caller. A command substitution
  # in the trap would run the trap again, TRY_INTERNAL_COUNT=0 lists the variables without one.
  exit() {
    local TRY_INTERNAL_STATUS=$?
    [[ $BASHPID == "$TRY_INTERNAL_PID" ]] || builtin exit "${1-$TRY_INTERNAL_STATUS}"
    { try_internal_xtrace_off; } 2>/dev/null
    TRY_INTERNAL_EXIT="${1-$TRY_INTERNAL_STATUS}"
    builtin set +e
    builtin trap - ERR
    builtin shopt -s extdebug
    builtin trap '[[ ${FUNCNAME[0]} != try_internal_child ]] || try_internal_dump "$TRY_INTERNAL_EXIT"; [[ ${FUNCNAME[0]} != TRY_INTERNAL_F ]] || { TRY_INTERNAL_COUNT=0; eval "$TRY_INTERNAL_BLOCK_END"; }; try_internal_status 2' DEBUG
  }
  # wait without ids also waits for process substitutions (since bash 5.0, with -n since 5.3), which are the relay and
  # the reader here. So it gets the ids of the background jobs of the try block.
  wait() {
    local TRY_INTERNAL_ARG TRY_INTERNAL_IDS= TRY_INTERNAL_ANY= TRY_INTERNAL_SKIP= IFS=$' \t\n'
    local -a TRY_INTERNAL_JOBS
    if [[ $BASHPID != "$TRY_INTERNAL_PID" ]]; then
      builtin wait "$@"
      builtin return
    fi
    for TRY_INTERNAL_ARG in "$@"; do
      if [[ -n $TRY_INTERNAL_SKIP ]]; then
        # the variable name of -p
        TRY_INTERNAL_SKIP=
        continue
      fi
      case "$TRY_INTERNAL_ARG" in
        --) ;;
        -*p) TRY_INTERNAL_SKIP=1 ;;&
        -*n*) TRY_INTERNAL_ANY=1 ;;
        -*) ;;
        "$TRY_INTERNAL_RELAY_PID" | "${TRY_INTERNAL_READER:-$TRY_INTERNAL_RELAY_PID}")
          # $! at the start of the try block: the last background job of the caller is not known here
          builtin printf 'try_catch.sh: wait: pid %s is not a child of the try block\n' "$TRY_INTERNAL_ARG" >&2
          builtin return 127
          ;;
        *) TRY_INTERNAL_IDS=1 ;;
      esac
    done
    if [[ -n $TRY_INTERNAL_IDS ]]; then
      builtin wait "$@"
      builtin return
    fi
    TRY_INTERNAL_JOBS=($(builtin jobs -p))
    if [[ -n $TRY_INTERNAL_ANY ]]; then
      # the next job that ends
      [[ ${#TRY_INTERNAL_JOBS[@]} != 0 ]] || builtin return 127
      builtin wait "$@" "${TRY_INTERNAL_JOBS[@]}"
      builtin return
    fi
    # all jobs, the builtin returns 0 for that
    [[ ${#TRY_INTERNAL_JOBS[@]} == 0 ]] || builtin wait "$@" "${TRY_INTERNAL_JOBS[@]}" || :
  }
  # When bash exits because of errexit, the variable scopes of all functions are gone before the EXIT trap runs.
  # So on error the ERR trap returns from one function after another until the try block itself returned.
  builtin trap '{ TRY_INTERNAL_RC=$?; TRY_INTERNAL_XT=; [[ ! -o xtrace ]] || TRY_INTERNAL_XT=1; builtin set +x; } 2>/dev/null; if try_internal_on_err; then [[ -n $TRY_INTERNAL_XTRACE_END ]] || TRY_INTERNAL_XTRACE_END=${TRY_INTERNAL_XT:-0}; [[ ${FUNCNAME[0]} != TRY_INTERNAL_F ]] || eval "$TRY_INTERNAL_BLOCK_END"; builtin return "$TRY_INTERNAL_RC"; fi; [[ -z $TRY_INTERNAL_XT ]] || builtin set -x' ERR
  # only reached if bash exits without ERR trap, e.g. because of set -u. The variables can't be passed back then.
  builtin trap 'TRY_INTERNAL_RC=$?; [[ -n $TRY_INTERNAL_DUMPED ]] || try_internal_dump "$TRY_INTERNAL_RC" novars' EXIT
  if [[ $1 == 1 ]]; then
    exec {TRY_INTERNAL_STDERR_FD}>&2 2> >(try_internal_reader)
    TRY_INTERNAL_READER=$!
    try_internal_high_fd TRY_INTERNAL_STDERR_FD
  fi
  builtin shift
  TRY_INTERNAL_ARGS_BEFORE=("$@")
  try_internal_snapshot
  builtin shopt -s inherit_errexit
  builtin set -eET -o pipefail
  [[ $TRY_INTERNAL_RESTORE != *a* ]] || builtin set -a
  TRY_INTERNAL_OPTIONS_BEFORE="$SHELLOPTS" TRY_INTERNAL_SHOPTS_BEFORE="$BASHOPTS"
  TRY_INTERNAL_F "$@"
  try_internal_dump 0
}

# called with the arguments of "trap -p", sets TRY_INTERNAL_CALLER_ERR
try_internal_trap_action() {
  [[ $1 != -- ]] || builtin shift
  TRY_INTERNAL_CALLER_ERR="$1"
}

# reads stderr of the try block (catcherr) and sends it to the relay
try_internal_reader() {
  { builtin set +x; } 2>/dev/null
  local TRY_INTERNAL_PART
  local -a TRY_INTERNAL_PARTS=()
  # until end of file, split at NUL bytes because read can't return them
  while IFS= builtin read -r -d '' TRY_INTERNAL_PART; do
    TRY_INTERNAL_PARTS+=("$TRY_INTERNAL_PART")
  done
  TRY_INTERNAL_PARTS+=("$TRY_INTERNAL_PART")
  builtin printf -v TRY_INTERNAL_PART '%q\n' "${TRY_INTERNAL_PARTS[@]}"
  try_internal_send S "${TRY_INTERNAL_PART%$'\n'}" "$TRY_INTERNAL_TO_RELAY"
}

# returns 0 if the ERR trap should return from the current function
try_internal_on_err() {
  if [[ ${FUNCNAME[1]} == try_internal_child && $TRY_INTERNAL_RETURN_DEPTH == "$TRY_INTERNAL_F_DEPTH" ]]; then
    try_internal_dump "$TRY_INTERNAL_RC"
  fi
  if [[ -z $TRY_INTERNAL_UNWINDING ]]; then
    try_internal_status "$TRY_INTERNAL_RC"
    eval "$TRY_INTERNAL_USER_ERR"
  fi
  [[ $BASHPID == "$TRY_INTERNAL_PID" ]] && [[ -o errexit ]] || builtin return 1
  TRY_INTERNAL_UNWINDING=1
  [[ ${FUNCNAME[1]} != try_internal_child ]] || try_internal_dump "$TRY_INTERNAL_RC"
  builtin return 0
}

try_internal_status() { builtin return "$1"; }

# $1: kind of the jump (break or continue), $2: the value of $_ after it, sets TRY_INTERNAL_JUMP when the jump left all
# TRY_INTERNAL_LOOPS loops. $_ is the argument of break/continue then (assuming it wasn't inside a loop of the block).
try_internal_deep_jump() {
  if [[ -n $2 && $2 != *[!0-9]* ]] && ((10#$2 > TRY_INTERNAL_LOOPS)); then
    TRY_INTERNAL_JUMP="$1 $((10#$2))"
  else
    TRY_INTERNAL_JUMP="$1 $TRY_INTERNAL_LOOPS"
  fi
}

# $1: exit code, $2: "novars" if the variable scopes are gone
try_internal_dump() {
  { builtin set +x; } 2>/dev/null
  local TRY_INTERNAL_RC="$1" TRY_INTERNAL_I TRY_INTERNAL_CODE= TRY_INTERNAL_DATA= TRY_INTERNAL_JUMP_CODE= \
    TRY_INTERNAL_OPTIONS_AFTER="$SHELLOPTS" TRY_INTERNAL_SHOPTS_AFTER="$BASHOPTS" TRY_INTERNAL_SER
  TRY_INTERNAL_DUMPED=1
  builtin set +eua
  builtin trap - ERR DEBUG
  builtin shopt -u extdebug nocasematch
  builtin unset -f trap exit wait
  eval "$TRY_INTERNAL_SAVED_FUNCS"
  # the EXIT trap of the try block: exit in it ends the subshell, then nothing is passed back
  try_internal_status "$TRY_INTERNAL_RC"
  eval "$TRY_INTERNAL_USER_EXIT"
  if [[ -n $TRY_INTERNAL_READER ]]; then
    # the reader reads until end of file, so it waits for background jobs that still have stderr open
    exec 2>&"$TRY_INTERNAL_STDERR_FD"
    builtin wait "$TRY_INTERNAL_READER"
  fi
  if [[ $TRY_INTERNAL_RETURN_DEPTH == "$TRY_INTERNAL_F_DEPTH" ]]; then
    # return in the try block returns from the function that contains it
    TRY_INTERNAL_JUMP_CODE="return $TRY_INTERNAL_RC"
    TRY_INTERNAL_RC=0
  elif [[ -n $TRY_INTERNAL_JUMP && $TRY_INTERNAL_JUMP != none ]]; then
    # break or continue in the try block that leaves it
    TRY_INTERNAL_JUMP_CODE="$TRY_INTERNAL_JUMP"
  elif [[ -n $TRY_INTERNAL_EXIT ]]; then
    TRY_INTERNAL_RC="$TRY_INTERNAL_EXIT"
  fi

  # variables (with IFS of the try block), aliases and the directory stack
  try_internal_diff "$2"
  [[ $2 == novars ]] || TRY_INTERNAL_CODE+="$TRY_INTERNAL_LOCALS_CODE"
  local IFS=$' \t\n'

  if [[ $PWD != "$TRY_INTERNAL_BEFORE_PWD" ]]; then
    builtin printf -v TRY_INTERNAL_SER 'builtin cd -- %q >/dev/null' "$PWD"
    TRY_INTERNAL_CODE+="$TRY_INTERNAL_SER"$'\n'
  fi
  # cd changes OLDPWD, repeating it once may not give the same value as in the try block
  if [[ $PWD != "$TRY_INTERNAL_BEFORE_PWD" || ${OLDPWD-} != "$TRY_INTERNAL_BEFORE_OLDPWD" ]]; then
    builtin printf -v TRY_INTERNAL_SER 'OLDPWD=%q' "${OLDPWD-}"
    TRY_INTERNAL_CODE+="$TRY_INTERNAL_SER"$'\n'
  fi
  try_internal_options "$TRY_INTERNAL_OPTIONS_BEFORE" "$TRY_INTERNAL_OPTIONS_AFTER" 'builtin set -o' 'builtin set +o'
  try_internal_options "$TRY_INTERNAL_SHOPTS_BEFORE" "$TRY_INTERNAL_SHOPTS_AFTER" 'builtin shopt -s' 'builtin shopt -u'
  # xtrace is only on while the try block itself runs
  TRY_INTERNAL_XTRACE_END="${TRY_INTERNAL_XTRACE_END:-${TRY_INTERNAL_XTRACE_BEFORE:-0}}"
  if [[ ${TRY_INTERNAL_XTRACE_BEFORE:-0} != "$TRY_INTERNAL_XTRACE_END" ]]; then
    if [[ $TRY_INTERNAL_XTRACE_END == 1 ]]; then TRY_INTERNAL_CODE+=$'builtin set -x\n'; else TRY_INTERNAL_CODE+=$'builtin set +x\n'; fi
  fi
  # traps for signals set in the try block (pairs of action and signal), repeated in the same order
  for ((TRY_INTERNAL_I = 0; TRY_INTERNAL_I < ${#TRY_INTERNAL_USER_TRAPS[@]}; TRY_INTERNAL_I += 2)); do
    builtin printf -v TRY_INTERNAL_SER 'builtin trap -- %q %q' "${TRY_INTERNAL_USER_TRAPS[TRY_INTERNAL_I]}" "${TRY_INTERNAL_USER_TRAPS[TRY_INTERNAL_I + 1]}"
    TRY_INTERNAL_CODE+="$TRY_INTERNAL_SER"$'\n'
  done
  # positional parameters (shift or set -- in the try block)
  if [[ -n $TRY_INTERNAL_HAVE_ARGS ]]; then
    builtin printf -v TRY_INTERNAL_SER ' %q' "${TRY_INTERNAL_ARGS[@]}"
    builtin printf -v TRY_INTERNAL_DATA ' %q' "${TRY_INTERNAL_ARGS_BEFORE[@]}"
    if [[ ${#TRY_INTERNAL_ARGS[@]} != "${#TRY_INTERNAL_ARGS_BEFORE[@]}" || $TRY_INTERNAL_SER != "$TRY_INTERNAL_DATA" ]]; then
      # printf prints the format once without arguments
      ((${#TRY_INTERNAL_ARGS[@]})) || TRY_INTERNAL_SER=
      TRY_INTERNAL_CODE+="builtin set --$TRY_INTERNAL_SER"$'\n'
    fi
  fi
  try_internal_send C "$TRY_INTERNAL_CODE" "$TRY_INTERNAL_TO_RELAY"
  try_internal_send J "$TRY_INTERNAL_JUMP_CODE" "$TRY_INTERNAL_TO_RELAY"
  try_internal_send K "$TRY_INTERNAL_COUNT" "$TRY_INTERNAL_TO_RELAY"
  # one command substitution for everything that can only be printed
  try_internal_send X "$(try_internal_state)" "$TRY_INTERNAL_TO_RELAY"
  try_internal_send E "" "$TRY_INTERNAL_TO_RELAY"
  builtin exit "$TRY_INTERNAL_RC"
}

# The try block is a function that contains TRY_INTERNAL_LOOPS loops with two iterations each. A break or continue in
# the try block that isn't meant for a loop inside of it ends up in one of them and is repeated in the caller.
try_internal_aliases() {
  # everything up to the catch block is the condition of an if, so try ... fi is one command that can be piped or
  # redirected as a whole
  local TRY_INTERNAL_I TRY_INTERNAL_TRY='if TRY_INTERNAL_F() { TRY_INTERNAL_JUMP= TRY_INTERNAL_BODY_RC=0; ' TRY_INTERNAL_END=
  TRY_INTERNAL_TRY+="for TRY_INTERNAL_L$TRY_INTERNAL_LOOPS in 1 2; do TRY_INTERNAL_N=\$_; if [[ \$TRY_INTERNAL_L$TRY_INTERNAL_LOOPS == 2 ]]; then try_internal_deep_jump continue \"\$TRY_INTERNAL_N\"; break 1; fi; "
  for ((TRY_INTERNAL_I = TRY_INTERNAL_LOOPS - 1; TRY_INTERNAL_I >= 1; TRY_INTERNAL_I--)); do
    TRY_INTERNAL_TRY+="for TRY_INTERNAL_L$TRY_INTERNAL_I in 1 2; do if [[ \$TRY_INTERNAL_L$TRY_INTERNAL_I == 2 ]]; then TRY_INTERNAL_JUMP='continue $TRY_INTERNAL_I'; break $((TRY_INTERNAL_LOOPS - TRY_INTERNAL_I + 1)); fi; "
  done
  # xtrace of the caller is turned on for the try block only
  TRY_INTERNAL_TRY+="[[ -z \$TRY_INTERNAL_XTRACE ]] || builtin set -x; "
  TRY_INTERNAL_END=" { TRY_INTERNAL_BODY_RC=\$?; try_internal_xtrace_off; } 2>/dev/null; TRY_INTERNAL_JUMP=none; break $TRY_INTERNAL_LOOPS; done; "
  for ((TRY_INTERNAL_I = 1; TRY_INTERNAL_I < TRY_INTERNAL_LOOPS; TRY_INTERNAL_I++)); do
    TRY_INTERNAL_END+="TRY_INTERNAL_JUMP=\${TRY_INTERNAL_JUMP:-'break $TRY_INTERNAL_I'}; break $((TRY_INTERNAL_LOOPS - TRY_INTERNAL_I)); done; "
  done
  TRY_INTERNAL_END+="TRY_INTERNAL_N=\$_; { try_internal_xtrace_off; } 2>/dev/null; [[ -n \$TRY_INTERNAL_JUMP ]] || try_internal_deep_jump break \"\$TRY_INTERNAL_N\"; "
  TRY_INTERNAL_END+="eval \"\$TRY_INTERNAL_BLOCK_END\"; builtin return \"\$TRY_INTERNAL_BODY_RC\"; }; "
  # Code outside of functions or with set -E runs the ERR trap, so errors in the try block have to run it too.
  # trap -p only shows it in the scope of the caller (not in functions without set -E). A command substitution
  # prints the traps of its parent, it is only needed if there is an ERR trap: with a closed stdout "trap -p" fails if
  # it has something to print. Inside of a try block the library knows the ERR trap.
  TRY_INTERNAL_END+="TRY_INTERNAL_ERR_TRAP=; if [[ -z \${TRY_INTERNAL_PID-} ]] && { [[ -o errtrace || -z \${FUNCNAME-} ]] || [[ \${FUNCNAME-} == source ]]; } && ! builtin trap -p ERR >&- 2>/dev/null; then TRY_INTERNAL_ERR_TRAP=\$(builtin trap -p ERR); fi; "
  # the result is applied with || :, so a part that can't be applied doesn't end the caller (set -e)
  alias try="$TRY_INTERNAL_TRY"
  alias catch="$TRY_INTERNAL_END"'try_internal_run 0 "$@"; eval "$TRY_INTERNAL_APPLY" || :; [[ "$ERR" != 0 ]]; then '
  # deprecated: catch preserves variables now
  alias catchvars="${BASH_ALIASES[catch]}"
  # stderr first, the applied code can end with return, break or continue
  alias catcherr="$TRY_INTERNAL_END"'try_internal_run 1 "$@"; if [[ "$ERR" = 0 ]]; then trystderr; fi; eval "$TRY_INTERNAL_APPLY" || :; [[ "$ERR" != 0 ]]; then '
}
try_internal_aliases
unset -f try_internal_aliases

# the functions of the library, see try_internal_state
try_internal_functions() {
  local TRY_INTERNAL_LINE
  local -a TRY_INTERNAL_LINES
  TRY_INTERNAL_FUNCTIONS=()
  try_internal_lines "$(builtin declare -F)"
  for TRY_INTERNAL_LINE in "${TRY_INTERNAL_LINES[@]}"; do
    TRY_INTERNAL_LINE="${TRY_INTERNAL_LINE##* }"
    [[ $TRY_INTERNAL_LINE != try_internal_* ]] || TRY_INTERNAL_FUNCTIONS+=("$TRY_INTERNAL_LINE")
  done
}
try_internal_functions
unset -f try_internal_functions

# Since bash 5.2 the syntax inside of $( ) and <( ) is checked before aliases are expanded, so a try/catch can't end
# with the reserved words fi or else there. These words are not reserved and work everywhere.
alias yrt='fi'
alias nocatch='else'

# return records the depth of the function it returns from, so return in a try block can return from the caller
# (FUNCNAME is unset outside of functions, 10#0 also works with set -u there)
alias return='builtin return ${TRY_INTERNAL_NONE[TRY_INTERNAL_RETURN_DEPTH=10#0${FUNCNAME+${#FUNCNAME[@]}}]-}'

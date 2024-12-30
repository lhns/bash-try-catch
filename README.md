# bash-try-catch

Proper error handling for bash.

Migrated from https://gist.github.com/lhns/4ce68fb18979cbf4262fc87f1bff45b1

## Usage

This script allows you to use proper error handling in bash that doesn't behave in weird ways when being nested/composed.

### try catch fi

Surround code that might fail with `try` and `catch` to catch any errors that might occur in that section.
The return code can be accessed with `$ERR`

> [!WARNING]  
> Variables that are declared in the try block are not visible in and after the catch block by default.

```bash
source try_catch.sh

try
  test="hello world" # will not be visible after try block
  # code that could fail
catch
  echo "error code: $ERR" >&2
  echo "$test" # will be empty
  # do something on error
fi

echo "$test" # will be empty
# do something afterwards
```

### try catchvars fi

`catchvars` will make all variables declared in the try block visible afterwards.

```bash
source try_catch.sh

try
  test="hello world" # will not be visible after try block
  # code that could fail
catchvars
  echo "error code: $ERR" >&2
  echo "$test" # will print "hello world"
  # do something on error
fi

echo "$test" # will print "hello world"
# do something afterwards
```

### try catcherr fi

`catcherr`, like `catchvars` will make all variables declared in the try block visible afterwards.
Additionally `catcherr` will capture stderr from the try block and make it available by calling `trystderr`

```bash
source try_catch.sh

try
  test="hello world" # will not be visible after try block
  echo "my important error message" >&2
  throw
catchvars
  echo "error code: $ERR" >&2
  echo "$test" # will print "hello world"
  echo "$(trystderr)" # will print "my important error message"
  # do something on error
fi

echo "$test" # will print "hello world"
# do something afterwards
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

## License

This project uses the Apache 2.0 License. See the file called LICENSE.

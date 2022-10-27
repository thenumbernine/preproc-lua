[![Donate via Stripe](https://img.shields.io/badge/Donate-Stripe-green.svg)](https://buy.stripe.com/00gbJZ0OdcNs9zi288)<br>
[![Donate via Bitcoin](https://img.shields.io/badge/Donate-Bitcoin-green.svg)](bitcoin:37fsp7qQKU8XoHZGRQvVzQVP8FrEJ73cSJ)<br>

## C preprocessor in Lua

Useful for luajit ffi cdefs just straight up using the .h files

Depends on:
- [lua-ext](https://github.com/thenumbernine/lua-ext)
- [lua-template](https://github.com/thenumbernine/lua-template)

## `generate.lua` ##

This file generates stripped header files from C header files.
The stripped headers are specific to LuaJIT:
-) They have #define constants replaced with enum{}'s.
-) They have function prototypes preserved.

`luajit generate.lua <optional-args> <include-file1> <include-file2> ...`

optional-args:
	-I<include-dir> = add extra include directory search path
	-M<macro-name>[=<macro-value>] = add extra macro
	-skip <include-file> = include and skip the specified include -- do not include its contents in the header generation.

## `preproc.lua` ##

This is the lua file for preprocessor class.

process a single file:
```
local Preproc = require 'preproc'
print(Preproc(code))
```

process a single file with some options:
```
local Preproc = require 'preproc'
print(Preproc{
	code = code,
	includeDirs = {...},
	macros = {...},
})
```

process multiple files:
```
local Preproc = require 'preproc'
local preproc = Preproc()
print(preproc{
	code = '#include <file1.h>',
	macros = ...,
	includeDirs = ...,
})
print(preproc{
	code = '#include <file2.h>',
	macros = ...,
	includeDirs = ...,
})

```

or modify the state as we go:
```
preproc:setMacros{
	KEY1 = 'value1',
	KEY2 = 'value2',
	...
}
preproc:addIncludeDir'path/too/foo/bar.h'
preproc:addIncludeDirs{
	'dir1/file1.h',
	'dir2/file2.h',
	...
}
```

returns an object that is cast to its .code field which contains the result.
this way you can query the .macros, .alreadyIncludedFiles, etc after preprocessing

processing multiple files retains the state of .macros and .alreadyIncludedFiles.

the call() operator returns the last file processed.

TODO should .code hold the last file processed, or the total files processed?

TODO If I'm in the middle of a typedef or enum or something with {}'s, I should wait to insert the #define => enum{} code.  (pthread.h)

TODO if you have a number value like enum {A = 0}; then do recursive def #define A A, which because it's a number value is turned into an enum, then this will still insert that second enum.  (pthread.h)

my attempt at a C preprocessor in Lua
useful for luajit ffi cdefs just straight up using the .h files
depends on my lua-ext lib

usage:

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
print(Preproc
```

returns an object that is cast to its .code field which contains the result.
this way you can query the .macros, .alreadyIncludedFiles, etc after preprocessing

processing multiple files retains the state of .macros and .alreadyIncludedFiles.

the call() operator returns the last file processed.

TODO should .code hold the last file processed, or the total files processed?

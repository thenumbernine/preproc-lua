[![Donate via Stripe](https://img.shields.io/badge/Donate-Stripe-green.svg)](https://buy.stripe.com/00gbJZ0OdcNs9zi288)<br>

## C preprocessor in Lua

This is a C preprocessor in Lua.

## `preproc.lua` ##

This is the lua file for preprocessor class.

process a single file:
``` Lua
local Preproc = require 'preproc'
print(Preproc(code))
```

process a single file with some options:
``` Lua
local Preproc = require 'preproc'
print(Preproc{
	code = code,
	includeDirs = {...},
	macros = {...},
})
```

process multiple files:
``` Lua
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
``` Lua
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

returns an object that is cast to its `.code` field which contains the result.
this way you can query the `.macros`, `.alreadyIncludedFiles`, etc after preprocessing

processing multiple files retains the state of `.macros` and `.alreadyIncludedFiles`.

The `__call` operator returns the last file processed.

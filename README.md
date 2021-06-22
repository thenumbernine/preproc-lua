my attempt at a C preprocessor in Lua
useful for luajit ffi cdefs just straight up using the .h files
depends on my lua-ext lib

usage:

```
preproc(code)

preproc{
	code = code,
	includeDirs = {...},
	macros = {...},
}
```

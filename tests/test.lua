#!/usr/bin/env luajit
local assert = require 'ext.assert'

local Preproc = require 'preproc'
--local Preproc = require 'preproc.preproc-old'
local p = Preproc()

local results = p[[
printf("testing\n");
#define X 1
printf("one two\n");
]]

-- did the p pull the macro out of the results correctly?
assert.eq(results, [[
printf("testing\n");
printf("one two\n");]])

-- did it store the macro?
assert.eq(p.macros.X, '1')

-- does the macro expand?
local result = p[[X]]
assert.eq(result, '1')

-- no-value defines?
p[[
#define Y
]]
assert.eq(p.macros.Y, '')

-- param macros?
local result = p[[
#define Z(a,b,c) a + b * c
]]

local Z = p.macros.Z
assert.len(Z.def, 5)
assert.tableieq(Z.def:mapi(function(e) return e.token end), {'a', '+', 'b', '*', 'c'})
assert.tableieq(Z.def:mapi(function(e) return e.type end), {'name', 'symbol', 'name', 'symbol', 'name'})
assert.tableieq(Z.params, {'a', 'b', 'c'})
--[=[

-- assert error:
local p = Preproc[[
#define X(1)	// bad ... "invalid token in macro processing" at the '1'
]]

-- assert error:
local p = Preproc[[
#define Y (a)	((a)+1)	// bad ... "use of undeclared 'a'"
]]
--]=]

local p = Preproc()
local results = p[[
#define X (1)	// good
#define Y(a) ((a)+1)	// good
int main() {
	printf("X = %d\n", X);			// replaced with 1
	printf("Y = %d\n", Y(1));		// replaced with ((1)+1)
}
]]
assert.eq(results, [[
int main() { printf("X = %d\n",(1));
printf("Y = %d\n", ((1)+1));
}]])

p = Preproc()
p[[
#if defined (notdefined)
#endif
]]

assert.error(function()
	p = Preproc()
	p[[
	#error here
	]]
end)

assert.error(function()
	p = Preproc()
	p[[
	#if defined (notdefined)
	#else
		#error "here"
	#endif
	]]
end)

p = Preproc()
p[[
#if defined (notdefined)
	#error "here"
#else
#endif
]]

p = Preproc()
p[[
#define __STDC_VERSION__ 201710L
#if __STDC_VERSION__ < 199901
#endif
]]

p = Preproc{sysIncludeDirs={'/usr/local/include'}}
p[[
#if __has_include(<stdio.h>)
#endif
]]

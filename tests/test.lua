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
assert.eq(Z.def, 'a + b * c')
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
print(results)

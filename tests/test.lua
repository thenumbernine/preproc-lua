#!/usr/bin/env luajit
local assert = require 'ext.assert'

local Preproc = require 'preproc'
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

-- no-value defines?
p[[
#define Y
]]
print(p.macros.Y)

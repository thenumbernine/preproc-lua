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

-- no-value defines?
p[[
#define Y
]]
assert.eq(p.macros.Y, '')

-- param macros?
p[[
#define Z(a,b,c) a + b * c
]]

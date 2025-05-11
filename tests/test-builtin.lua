#!/usr/bin/env luajit
local io = require 'ext.io'
local os = require 'ext.os'
local tolua = require 'ext.tolua'

assert(os.exec'gcc --version > /dev/null 2>&1', "failed to find gcc")	-- make sure we have gcc
local macros = io.readproc'gcc -dM -E - < /dev/null 2>&1'

print'========= BEGIN BUILTIN MACROS ========='
print(macros)
print'========= END BUILTIN MACROS ========='

local Preproc = require 'preproc'
local p = Preproc()
p(macros)

print(tolua(p.macros.__PTRDIFF_TYPE__))

local result = p[[
typedef __PTRDIFF_TYPE__ ptrdiff_t;
]]
print(result)

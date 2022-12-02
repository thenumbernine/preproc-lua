#!/usr/bin/env lua

local file = require 'ext.file'
local table = require 'ext.table'

-- this holds the stuff thats working already
-- but it's a separate file for the sake of generate.lua looking to see what to replace with require()'s
local includeList = require 'include-list'

local req = ...
if not req then error("make_all.lua all for all, or make_all.lua <some filename>") end
if req ~= 'all' then
	includeList = table.filter(includeList, function(inc)
		--return inc.inc:match(req)
		return inc.inc == req
	end):setmetatable(nil)
end

local function exec(cmd)
	print('>'..cmd)
	return os.execute(cmd)
end

local outdir = 'results'
for _,inc in ipairs(includeList) do
	if not inc.dontGen then
		local outpath = outdir..'/'..inc.out
		local dir,outfn = file(outpath):getdir()
		file(dir):mkdir(true)
		file(outpath):write[=[
local ffi = require 'ffi'
ffi.cdef[[
]=]
		local cmd = table{
			'luajit',
			'generate.lua'
		}
		if inc.flags then
			cmd:insert(inc.flags)
		end
		local function addincarg(f)
			if f:sub(1,1) == '"' then
				cmd:insert(('%q'):format(f))
			elseif f:sub(1,1) == '<' then
				cmd:insert(f)
			else
				cmd:insert('"<'..f..'>"')
			end
		end
		addincarg(inc.inc)
		if inc.moreincs then
			for _,f in ipairs(inc.moreincs) do
				addincarg(f)
			end
		end
		cmd:append{
			'>>',
			'"'..outpath..'"',
		}
		cmd = cmd:concat' '
		print(exec(cmd))
		file(outpath):append[=[
]]
]=]
		-- if there's a final-pass on the code then do it
		if inc.final then
			assert(file(outpath):write(
				assert(inc.final(
					assert(file(outpath):read())
				), "expected final() to return a string")
			))
		end

		-- verify ...
		-- can't use -lext because that will load ffi/c stuff which could cause clashes in cdefs
		print(exec([[luajit -e "assert(load(require 'ext.io'.readfile']]..outpath..[['))()"]]))
	end
end

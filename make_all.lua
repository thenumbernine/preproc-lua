#!/usr/bin/env lua

local path = require 'ext.path'
local table = require 'ext.table'

-- this holds the stuff thats working already
-- but it's a separate file for the sake of generate.lua looking to see what to replace with require()'s
local includeList = require 'include-list'

local req = ...
if not req then error("make_all.lua all for all, or make_all.lua <some filename>") end
if req ~= 'all' then
	-- TODO seems using <> or "" now is essential for excluding recursive require's
	if req:sub(1,1) ~= '<' and req:sub(1,1) ~= '"' then error("gotta be system or user include space") end
	print('searching for '..req)
	includeList = table.filter(includeList, function(inc)
		--return inc.inc:match(req)
		return inc.inc == req
	end):setmetatable(nil)
	if #includeList == 0 then
		error("couldn't find "..req)
	end
end

local function exec(cmd)
	print('>'..cmd)
	return os.execute(cmd)
end

local outdir = 'results'
for _,inc in ipairs(includeList) do
	if not inc.dontGen then
		local outpath = outdir..'/'..inc.out
		local dir,outfn = path(outpath):getdir()
		path(dir):mkdir(true)
		path(outpath):write[=[
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
				cmd:insert('"'..f..'"')
			else
				error'inc /moreincs needs <> or "" wrapper'
			end
		end
		addincarg(inc.inc)
		if inc.moreincs then
			for _,f in ipairs(inc.moreincs) do
				addincarg(f)
			end
		end
		for _,f in ipairs(inc.silentincs or {}) do
			cmd:insert'-silent'
			addincarg(f)
		end
		for _,f in ipairs(inc.skipincs or {}) do
			cmd:insert'-skip'
			addincarg(f)
		end
		if inc.addDefinesAsEnumsLast then
			cmd:insert'-addDefinesAsEnumsLast'
		end
		cmd:append{
			'>>',
			'"'..outpath..'"',
		}
		cmd = cmd:concat' '
		print(exec(cmd))
		path(outpath):append[=[
]]
]=]
		-- if there's a final-pass on the code then do it
		if inc.final then
			assert(path(outpath):write(
				assert(inc.final(
					assert(path(outpath):read())
				), "expected final() to return a string")
			))
		end

		-- verify ...
		-- can't use -lext because that will load ffi/c stuff which could cause clashes in cdefs
		print(exec([[luajit -e "assert(load(require 'ext.io'.readfile']]..outpath..[['))()"]]))
	end
end

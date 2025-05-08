#!/usr/bin/env luajit
local ffi = require 'ffi'
local path = require 'ext.path'
local table = require 'ext.table'
local os = require 'ext.os'

-- this holds the stuff thats working already
-- but it's a separate file for the sake of generate.lua looking to see what to replace with require()'s
local includeList = require 'include-list'
-- remove all those that pertain to other os/arch
includeList = includeList:filter(function(inc)
	if inc.os ~= nil and inc.os ~= ffi.os then return end
	if inc.arch ~= nil and inc.arch ~= ffi.arch then return end
	return true
end)

local req = ...
if not req then error("`make.lua all` for all, or `make.lua <sourceIncludeFile.h>`") end
if req ~= 'all' then
	-- TODO seems using <> or "" now is essential for excluding recursive require's
	if req:sub(1,1) ~= '<' and req:sub(1,1) ~= '"' then
		error('must be system (<...>) or user ("...") include space')
	end
	print('searching for '..req)
	includeList = table.filter(includeList, function(inc)
		--return inc.inc:match(req)
		return inc.inc == req
	end):setmetatable(nil)
	if #includeList == 0 then
		error("couldn't find "..req)
	end
end

local outdirbase = path'results'	-- outdir without ffi/
local outdir = outdirbase/'ffi'
for _,inc in ipairs(includeList) do
	if not inc.dontGen then
		local outpath = outdir/inc.out
		local dir, outfn = outpath:getdir()
		dir:mkdir(true)

		if inc.forcecode then
			-- just write it , proly a split between dif os versions
			outpath:write(inc.forcecode)
		else
			outpath:write[=[
local ffi = require 'ffi'
ffi.cdef[[
]=]
			local cmd = table{
				'luajit',
--DEBUG:		'-lext.debug',	-- debugging? forward debug tags?
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
			for _,m in ipairs(inc.includedirs or {}) do
				cmd:insert('-I'..m)
			end
			for _,m in ipairs(inc.macros or {}) do
				cmd:insert('-D'..m)
			end
			if inc.enumGenUnderscoreMacros then
				cmd:insert'-enumGenUnderscoreMacros'
			end
			cmd:append{'>>', outpath:escape()}

			cmd = cmd:concat' '
			assert(os.exec(cmd))

			outpath:append[=[
]]
]=]
			-- if there's a final-pass on the code then do it
			if inc.final then
				assert(outpath:write(
					assert(inc.final(
						assert(outpath:read())
					), "expected final() to return a string")
				))
			end
		end

		if ffi.os == 'Windows' then
			-- in windows, the linux code writes \n's, but the windows >> writes \r\n's,
			-- so unify them all here, pick whichever format you want
			outpath:write((
				outpath:read()
					:gsub('\r\n', '\n')
			))
		end

		-- verify it works
		-- can't use -lext because that will load ffi/c stuff which could cause clashes in cdefs
		-- luajit has loadfile, nice.
		--[=[ use loadfile ... and all the old/original ffi locations
		assert(os.exec([[luajit -e "assert(loadfile(']]..outpath..[['))()"]]))
		--]=]
		-- [=[ use require, and base it in the output folder
		assert(os.exec([[luajit -e "package.path=']]..outdirbase..[[/?.lua;'..package.path require 'ffi.req' ']]..assert((inc.out:match('(.*)%.lua'))):gsub('/', '.')..[['"]]))
		--]=]
	end
end

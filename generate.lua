#!/usr/bin/env luajit
local ffi = require 'ffi'		-- used for OS check and used for verifying that the generated C headers are luajit-ffi compatible
local file = require 'ext.file'
local table = require 'ext.table'
local string = require 'ext.string'
local io = require 'ext.io'

local preproc = require 'preproc'()

if ffi.os == 'Windows' then
	-- I guess pick these to match the compiler used to build luajit
	-- TODO this could work if my macro evaluator could handle undef'd comparisons <=> replace with zero
	preproc:setMacros{
		-- don't define this or khrplatform explodes with stdint.h stuff
		--__STDC_VERSION__ = '201710L',	-- c++17
		--__STDCPP_THREADS__ = '0',
		
		_MSC_VER = '1929',
		_MSC_FULL_VER = '192930038',
		_MSVC_LANG = '201402',
		_MSC_BUILD = '1',

	-- choose which apply:
		_M_AMD64 = '100',
		--_M_ARM = '7',
		--_M_ARM_ARMV7VE = '1',
		--_M_ARM64 = '1',
		--_M_IX86 = '600',
		_M_X64 = '100',

		_WIN32 = '1',
		_WIN64 = '1',
	}

	--[[ does this just setup the preproc state?
	-- or is there typedef stuff in here too?
	-- if so then feed it to ffi
	-- it gets into varargs and stringizing ...
	preproc'#include <windows.h>'
	--]]
	-- [[
	preproc:setMacros{
		-- these are used in gl.h, but where are they defined? probably windows.h
		WINGDIAPI = '',
		APIENTRY = '',
	}
	--]]
else	-- assume everything else uses gcc
	assert(os.execute'g++ --version > /dev/null 2>&1', "failed to find gcc")	-- make sure we have gcc
	preproc(io.readproc'g++ -dM -E - < /dev/null 2>&1')

	local results = io.readproc'g++ -xc++ -E -v - < /dev/null 2>&1'
--print('results')
--print(results)
	assert(results:match'include')
	assert(results:match('#include'))	-- why doesn't this match? 
	assert(results:match'#include "%.%.%." search starts here:')
	local userSearchStr, sysSearchStr = results:match'#include "%.%.%." search starts here:(.-)#include <%.%.%.> search starts here:(.-)End of search list%.'
	assert(userSearchStr)
--print('userSearchStr')
--print(userSearchStr)
--print('sysSearchStr')
--print(sysSearchStr)
	local userSearchDirs = string.split(string.trim(userSearchStr), '\n'):mapi(string.trim)
	local sysSearchDirs = string.split(string.trim(sysSearchStr), '\n'):mapi(string.trim)
--print('userSearchDirs')
--print(require 'ext.tolua'(userSearchDirs))
--print('sysSearchDirs')
--print(require 'ext.tolua'(sysSearchDirs))
	preproc:addIncludeDirs(userSearchDirs, false)
	preproc:addIncludeDirs(sysSearchDirs, true)

	-- how to handle gcc extension macros?
	preproc[[
#define __has_feature(x)		0
#define __has_extension(x)		0
#define __has_attribute(x)		0
#define __has_cpp_attribute(x)	0
#define __has_c_attribute(x)	0
#define __has_builtin(x)		0
#define __has_include(x)		0
]]
end


-- TODO do this externally so this is a more generic tool?
-- maybe some -M argument?
preproc:setMacros{GL_GLEXT_PROTOTYPES = '1'}


-- where I keep my glext.h and khr/khrplatform.h
-- TODO move this into gl.sh
preproc:addIncludeDir((os.getenv'USERPROFILE' or os.getenv'HOME')..'/include', false)
preproc:addIncludeDir('.', false)	-- cwd?

--[[
args:
	-I<incdir> = add include dir
	-skip <inc> = include it, add it to the state, but don't add it to the output
		useful for system files that you don't want mixed in there
--]]
local args = table{...}
local silentfiles = table()
do
	local i = 1
	while i <= #args do
		local f = args[i]
		if f:sub(1,2) == '-I' then
			-- how to tell sys or not?
			preproc:addIncludeDir(f:sub(3), true)
			args:remove(i)
		elseif f == "-skip" then
			args:remove(i)
			silentfiles:insert(args:remove(i))
		else
			i = i + 1
		end
	end
end
local incfiles = args	-- whatever is left is include files

--[[
windows' gl/gl.h defines the following:
#define GL_EXT_vertex_array               1
#define GL_EXT_bgra                       1
#define GL_EXT_paletted_texture           1
#define GL_WIN_swap_hint                  1
#define GL_WIN_draw_range_elements        1
// #define GL_WIN_phong_shading              1
// #define GL_WIN_specular_fog               1

probably because their functions/macros are in the gl.h header
BUT windows DOESNT define the true EXT-suffix functions
--]]
for _,fn in ipairs(silentfiles) do
	preproc("#include "..fn)
end
local code = preproc(incfiles:mapi(function(fn)
	return '#include '..fn
end):concat'\n'..'\n')

print(code)


--io.stderr:write('macros: '..require 'ext.tolua'(preproc.macros)..'\n')


-- see if there's any errors here
-- TODO There will almost always be errors if you used -skip, so how about in that case automatically include the luajit of the skipped files?
--local result = xpcall(function()
	ffi.cdef(code)
--end, function(err)
--	io.stderr:write('macros: '..require 'ext.tolua'(preproc.macros)..'\n')
--	io.stderr:wrie(err..'\n'..debug.traceback())
--end)
--os.exit(result and 0 or 1)

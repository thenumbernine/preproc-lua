#!/usr/bin/env luajit
local ffi = require 'ffi'
local file = require 'ext.file'
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
end

-- where I keep my glext.h and khr/khrplatform.h
preproc:addIncludeDir((os.getenv'USERPROFILE' or os.getenv'HOME')..'/include', false)
preproc:setMacros{GL_GLEXT_PROTOTYPES = '1'}

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
local gl = preproc[[
#include <GL/gl.h>
#include <GL/glext.h>
]]
file['gl.h'] = gl
ffi.cdef(gl)

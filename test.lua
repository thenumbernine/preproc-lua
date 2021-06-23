local ffi = require 'ffi'
local file = require 'ext.file'

local preproc = require 'preproc'()

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

-- where I keep my glext.h and khr/khrplatform.h
preproc:addIncludeDir((os.getenv'USERPROFILE' or os.getenv'HOME')..'/include')

preproc:setMacros{
	GL_GLEXT_PROTOTYPES = '',
}

local gl = preproc[[
#include <GL/gl.h>
#include <GL/glext.h>
]]
file['gl.h'] = gl
ffi.cdef(gl)

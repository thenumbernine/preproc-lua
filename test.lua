local ffi = require 'ffi'
local file = require 'ext.file'

local preproc = require 'preproc'()


-- I guess pick these to match the compiler used to build luajit
-- TODO this could work if my macro evaluator could handle undef'd comparisons <=> replace with zero
preproc:setMacros{
	_WIN32 = '1',
	_MSC_VER = '1929',
	_MSVC_LANG = '201402',
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

local code = preproc'#include <GL/gl.h>'
file['gl.h'] = code
ffi.cdef(code)

preproc:addIncludeDir((os.getenv'USERPROFILE' or os.getenv'HOME')..'/include')

local code = preproc'#include <KHR/khrplatform.h>'
file['khrplatform.h'] = code
ffi.cdef(code)

--[[
preproc:setMacros{
	GL_GLEXT_PROTOTYPES = '',
}
local code = preproc'#include <GL/glext.h>'
file['glext.h'] = code
ffi.cdef(code)
--]]

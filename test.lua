local ffi = require 'ffi'
local file = require 'ext.file'

local preproc = require 'preproc'()
preproc:setMacros{
	-- I guess pick these to match the compiler used to build luajit
	-- TODO this could work if my macro evaluator could handle undef'd comparisons <=> replace with zero
	_WIN32 = '1',
	_MSC_VER = '1929',
	WINGDIAPI = '',
	APIENTRY = '',
}
local code = preproc'#include <GL/gl.h>'
file['gl.h'] = code
ffi.cdef(code)

preproc:setMacros{
	GL_GLEXT_PROTOTYPES = '',
}
preproc:addIncludeDir((os.getenv'USERPROFILE' or os.getenv'HOME')..'/include')
local code = preproc'#include <GL/glext.h>'
file['glext.h'] = code
ffi.cdef(code)

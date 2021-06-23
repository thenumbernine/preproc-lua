local ffi = require 'ffi'
local file = require 'ext.file'

local preproc = require 'preproc'()
local code = preproc{
	code = '#include <GL/gl.h>',
	macros = {
		-- I guess pick these to match the compiler used to build luajit
		-- TODO this could work if my macro evaluator could handle undef'd comparisons <=> replace with zero
		_WIN32 = '1',
		_MSC_VER = '1929',
		WINGDIAPI = '',
		APIENTRY = '',
	},
}
file['gl.h'] = code
ffi.cdef(code)

local code = preproc{
	code = '#include <GL/glext.h>',
	includeDirs = {
		os.getenv'USERPROFILE'..'/include'
	},
	macros = {
		GL_GLEXT_PROTOTYPES = '',
	},
}
file['glext.h'] = code
ffi.cdef(code)

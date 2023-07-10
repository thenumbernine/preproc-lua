-- mapping from c includes to luajit ffi/ includes
-- this is used for automated generation
-- this is also used during generation for swapping out #includes with require()'s of already-generated files

local string = require 'ext.string'
local table = require 'ext.table'
local io = require 'ext.io'

local function remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
	return (code:gsub('enum { __GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION = 1 };\n', ''))
end

-- pid_t and pid_t_defined are manually inserted into lots of dif files
-- i've separated it into its own file myself, so it has to be manually replaced
-- same is true for a few other types
local function replace_bits_types_builtin(code, ctype)
	code = code:gsub(string.patescape([[
typedef __]]..ctype..[[ ]]..ctype..[[;
enum { __]]..ctype..[[_defined = 1 };]]),
		[=[]] require 'ffi.c.bits.types.]=]..ctype..[=[' ffi.cdef[[]=]
	)
	return code
end

local function remove_need_macro(code, name)
	code = code:gsub('enum { __need_'..name..' = 1 };\n', '')
	return code
end

-- _VA_LIST_DEFINED and va_list don't appear next to each other like the typical bits_types_builtin do
local function remove_VA_LIST_DEFINED(code)
	code = code:gsub('enum { _VA_LIST_DEFINED = 1 };\n', '')
	return code
end

local function replace_va_list_require(code)
	code = code:gsub(
		'typedef __gnuc_va_list va_list;',
		[=[]] require 'ffi.c.va_list' ffi.cdef[[]=]
	)
	return code
end

-- TODO keeping warnings as comments seems nice
--  but they insert at the first line
--  which runs the risk of bumping the first line skip of BEGIN ...
--  which could replcae the whole file with a require()
local function removeWarnings(code)
	return code:gsub('warning:[^\n]*\n', '')
end

local function commentOutLine(code, line)
	code = code:gsub(
		string.patescape(line),
		'/* manually commented out: '..line..' */')
	return code
end

-- these all have some inlined enum errors:
--  caused from #define spitting out an enum intermingled in the lines of an enum { already present
local function fixEnumsAndDefineMacrosInterleaved(code)
	local lines = string.split(code, '\n')
	lines = lines:mapi(function(l)
		local a,b = l:match'^(.*) enum { (.*) = 0 };$'
		if a then
			-- there will be a trailing comma in all but the last of an enum
			-- there may or may not be an "= value" in 'a' also
			local comma = ''
			if a:sub(-1) == ',' then
				comma = ','
				a = a:sub(1,-2)
			end
			-- TODO this might match even if a and b are different, even if b is a suffix of a
			-- but honestly why even constraint a and b to be equal, since
			-- at this point there's two enums on the same line, which i'm trying to avoid
			if a:match(string.patescape(b)) then
				return a..comma..'/* enum { '..b..' = 0 }; */'
			end
		end
		return l
	end)
	return lines:concat'\n'
end

return {
	{inc='<stddef.h>', out='c/stddef.lua'},
	{inc='<features.h>', out='c/features.lua'},
	{inc='<bits/endian.h>',	out='c/bits/endian.lua'},
	{inc='<bits/types/locale_t.h>',	out='c/bits/types/locale_t.lua'},
	{inc='<bits/types/__sigset_t.h>',	out='c/bits/types/__sigset_t.lua'},

	{inc='<bits/wchar.h>', out='c/bits/wchar.lua'},

	-- depends: features.h
	{inc='<bits/floatn.h>',	out='c/bits/floatn.lua'},
	{inc='<bits/types.h>', out='c/bits/types.lua', final=function(code)
		-- manually:
		-- `enum { __FD_SETSIZE = 1024 };`
		-- has to be replaced with
		-- `]] require 'ffi.c.__FD_SETSIZE' ffi.cdef[[`
		-- because it's a macro that appears in a few places, so I manually define it.
		-- (and maybe also write the file?)
		return (code:gsub(
			'enum { __FD_SETSIZE = 1024 };',
			[=[]] require 'ffi.c.__FD_SETSIZE' ffi.cdef[[]=]
		))
	end},
	
	-- depends: bits/types.h
	{inc='<bits/stdint-intn.h>',	out='c/bits/stdint-intn.lua'},
	{inc='<bits/types/clockid_t.h>',	out='c/bits/types/clockid_t.lua'},
	{inc='<bits/types/clock_t.h>',	out='c/bits/types/clock_t.lua'},
	{inc='<bits/types/struct_timeval.h>',	out='c/bits/types/struct_timeval.lua'},
	{inc='<bits/types/timer_t.h>',	out='c/bits/types/timer_t.lua'},
	{inc='<bits/types/time_t.h>',	out='c/bits/types/time_t.lua'},

	-- depends: bits/types.h bits/endian.h
	{inc='<bits/types/struct_timespec.h>',	out='c/bits/types/struct_timespec.lua'},
	
	{inc='<sys/ioctl.h>', out='c/sys/ioctl.lua'},

	{inc='<sys/select.h>', out='c/sys/select.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'suseconds_t')
		return code
	end},

	-- depends: features.h bits/types.h
	-- mind you i found in the orig where it shouldve require'd features it was requiring itself ... hmm ...
	{inc='<sys/termios.h>', out='c/sys/termios.lua'},

	-- depends: bits/types.h etc
	{inc='<sys/stat.h>', out='c/sys/stat.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'gid_t')
		code = replace_bits_types_builtin(code, 'uid_t')
		code = replace_bits_types_builtin(code, 'off_t')
		return code
	end},

	-- depends: features.h bits/types.h sys/select.h
	{inc='<sys/types.h>', out='c/sys/types.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'gid_t')
		code = replace_bits_types_builtin(code, 'uid_t')
		code = replace_bits_types_builtin(code, 'off_t')
		code = replace_bits_types_builtin(code, 'pid_t')
		code = replace_bits_types_builtin(code, 'ssize_t')
		code = remove_need_macro(code, 'size_t')
		return code
	end},

	{inc='<linux/limits.h>', out='c/linux/limits.lua', final=function(code)
		code = commentOutLine(code, 'enum { __undef_ARG_MAX = 1 };')
		return code
	end},

	-- depends: bits/libc-header-start.h linux/limits.h
	-- with this the preproc gets a warning:
	--  warning: redefining LLONG_MIN from -1 to -9.2233720368548e+18 (originally (-LLONG_MAX - 1LL))
	-- and that comes with a giant can of worms of how i'm handling cdef numbers vs macro defs vs lua numbers ...
	-- mind you I could just make the warning: output into a comment
	--  and there would be no need for manual manipulation here
	{inc='<limits.h>', out='c/limits.lua', final=function(code)
		-- warning for redefining LLONG or something
		code = removeWarnings(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		return code
	end},

	-- depends: features.h sys/types.h
	{inc='<stdlib.h>', out='c/stdlib.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'wchar_t')
		code = remove_need_macro(code, 'NULL')
		return code
	end},
	
	-- depends: features.h, bits/types/__sigset_t.h
	{inc='<setjmp.h>', out='c/setjmp.lua'},

	-- depends on features.h
	{inc='<errno.h>', out='c/errno.lua', final=function(code)
		-- manually add the 'errno' macro at the end:
		code = code .. [[
return setmetatable({
	errno = function()
		return ffi.C.__errno_location()[0]
	end,
}, {
	__index = ffi.C,
})
]]
		return code
	end},

	-- depends: features.h bits/types.h
	{inc='<unistd.h>', out='c/unistd.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'gid_t')
		code = replace_bits_types_builtin(code, 'uid_t')
		code = replace_bits_types_builtin(code, 'off_t')
		code = replace_bits_types_builtin(code, 'pid_t')
		code = replace_bits_types_builtin(code, 'ssize_t')
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'NULL')
		code = code:gsub(
			-- TODO i'm sure this dir will change in the future ...
			string.patescape('/* BEGIN /usr/include/x86_64-linux-gnu/bits/confname.h */')
			..'.*'
			..string.patescape('/* END   /usr/include/x86_64-linux-gnu/bits/confname.h */'),
			[[

/* TODO here I skipped conframe because it was too many mixed enums and ddefines => enums */
]]
		)
		code = code .. [[

-- I can't change ffi.C.getcwd to ffi.C._getcwd in the case of Windows
-- but I can at least return a table that changes names depending on the OS:
-- TODO do the __index trick, and split this file between Windows and Linux ?

if ffi.os == 'Windows' then
	return {
		chdir = ffi.C._chdir,
		getcwd = ffi.C._getcwd,
	}
else
	return {
		chdir = ffi.C.chdir,
		getcwd = ffi.C.getcwd,
	}
end
]]
		return code
	end},

	-- depends: stddef.h bits/types/time_t.h bits/types/struct_timespec.h
	{inc='<sched.h>', out='c/sched.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'pid_t')
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'NULL')
		return code
	end},
	
	-- depends: bits/types.h
	-- another where luajit -e "require 'results.c.stdint'" will work but luajit -e "assert(load(file'results/c/stdint.lua':read()))()" will give an error:
	--  `attempt to redefine 'WCHAR_MIN' at line 75
	-- because lua.ext already defined it
	{inc='<stdint.h>',	out='c/stdint.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		return code
	end},

	-- depends: features.h stddef.h bits/libc-header-start.h
	{inc='<string.h>', out='c/string.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'NULL')
		return code
	end},

	-- depends: features.h stddef.h bits/types.h and too many really
	-- this and any other file that requires stddef might have these lines which will have to be removed:
	{inc='<time.h>', out='c/time.lua', final=function(code)
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'NULL')
		code = replace_bits_types_builtin(code, 'pid_t')
		return code
	end},

	-- depends on too much
	{inc='<stdarg.h>', out='c/stdarg.lua', final=function(code)
		-- stdio.h and stdarg.h both define this
		-- typedef __gnuc_va_list va_list;
		-- enum { _VA_LIST_DEFINED = 1 };
		-- so maybe I should put it in its own manual file?
		code = remove_VA_LIST_DEFINED(code)
		code = replace_va_list_require(code)
		-- for fopen overloading
		code = code .. [[
-- special case since in the browser app where I'm capturing fopen for remote requests and caching
-- feel free to not use the returend table and just use ffi.C for faster access
-- but know you'll be losing compatability with browser
return setmetatable({}, {
	__index = ffi.C,
})
]]
		return code
	end},

	-- depends on too much
	{inc='<stdio.h>',	out='c/stdio.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		code = replace_bits_types_builtin(code, 'off_t')
		code = replace_bits_types_builtin(code, 'ssize_t')
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'NULL')
		code = remove_need_macro(code, '__va_list')
		code = remove_VA_LIST_DEFINED(code)
		code = replace_va_list_require(code)
		-- this all stems from #define stdin stdin etc
		-- which itself is just for C99/C89 compat
		code = commentOutLine(code, 'enum { stdin = 0 };')
		code = commentOutLine(code, 'enum { stdout = 0 };')
		code = commentOutLine(code, 'enum { stderr = 0 };')
		return code
	end},

	{inc='<stdbool.h>', out='c/stdbool.lua', final=function(code)
		-- luajit has its own bools already defined
		code = commentOutLine(code, 'enum { bool = 0 };')
		code = commentOutLine(code, 'enum { true = 1 };')
		code = commentOutLine(code, 'enum { false = 0 };')
		return code
	end},

	-- depends: features.h stdint.h
	{inc='<inttypes.h>', out='c/inttypes.lua'},


-- requires manual manipulation:


	-- depends: features.h
	-- this is here for require() insertion but cannot be used for generation
	-- it must be manually created
	--
	-- they run into the "never include this file directly" preproc error
	-- so you'll have to manually cut out the generated macros from another file
	--  and insert the code into a file in the results folder
	-- also anything that includes this will have the line before it:
	--  `enum { __GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION = 1 };`
	-- and that will have to be removed
	{dontGen=true, inc='<bits/libc-header-start.h>', out='c/bits/libc-header-start.lua', final=function(code)
		return remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
	end},

	-- this is here for require() insertion but cannot be used for generation
	-- it must be manually extracted from c/setjmp.lua
	{dontGen=true, inc='<bits/setjmp.h>', out='c/bits/setjmp.lua'},
	
	{dontGen=true, inc='<bits/dirent.h>', out='c/bits/dirent.lua', final=function(code)
		code = commentOutLine(code, 'enum { __undef_ARG_MAX = 1 };')
		return code
	end},

	-- this file doesn't exist. stdio.h and stdarg.h both define va_list, so I put it here
	-- but i guess it doesn't even have to be here.
	--{dontGen=true, inc='<va_list.h>', out='c/va_list.lua'},

	-- same with just.  just a placeholder:
	--{dontGen=true, inc='<__FD_SETSIZE.h>', out='c/__FD_SETSIZE.lua'},

-- these come from external libraries (so I don't put them in the c/ subfolder)


	{
		inc='<zlib.h>',
		out='zlib.lua',
		final=function(code)
			-- LLONG_MIN warning
			code = removeWarnings(code)
			-- getting around the FAR stuff
			-- why am I generating an enum for it?
			-- and now just replace the rest with nothing
			code = code:gsub('enum { FAR = 1 };\n', '')
			code = code:gsub(' FAR ', ' ')
			-- same deal with z_off_t
			-- my preproc => luajit can't handle defines that are working in place of typedefs
			code = code:gsub('enum { z_off_t = 0 };\n', '')
			code = code:gsub('z_off_t', 'off_t')
			code = remove_need_macro(code, 'size_t')
			code = remove_need_macro(code, 'NULL')
			
			-- add some macros onto the end manually
			code = code .. [[

local zlib = ffi.load'z'
local wrapper
wrapper = setmetatable({
	ZLIB_VERSION = "1.2.11",
	deflateInit = function(strm)
		return zlib.deflateInit_(strm, wrapper.ZLIB_VERSION, ffi.sizeof'z_stream')
	end,
	inflateInit = function(strm)
		return zlib.inflateInit_(strm, wrapper.ZLIB_VERSION, ffi.sizeof'z_stream')
	end,
	deflateInit2 = function(strm, level, method, windowBits, memLevel, strategy)
		return zlib.deflateInit2_(strm, level, method, windowBits, memLevel, strategy, wrapper.ZLIB_VERSION, ffi.sizeof'z_stream')
	end,
	inflateInit2 = function(strm, windowBits)
		return zlib.inflateInit2_(strm, windowBits, wrapper.ZLIB_VERSION, ffi.sizeof'z_stream')
	end,
	inflateBackInit = function(strm, windowBits, window)
		return zlib.inflateBackInit_(strm, windowBits, window, wrapper.ZLIB_VERSION, ffi.sizeof'z_stream')
	end,
	pcall = function(fn, ...)
		local f = assert(wrapper[fn])
		local result = f(...)
		if result == zlib.Z_OK then return true end
		local errs = require 'ext.table'{
			'Z_ERRNO',
			'Z_STREAM_ERROR',
			'Z_DATA_ERROR',
			'Z_MEM_ERROR',
			'Z_BUF_ERROR',
			'Z_VERSION_ERROR',
		}:mapi(function(v) return v, assert(zlib[v]) end):setmetatable(nil)
		local name = errs[result]
		return false, fn.." failed with error "..result..(name and (' ('..name..')') or '')
	end,
}, {
	__index = zlib,
})
return wrapper
]]
			return code
		end,
	},

	-- apt install libffi-dev
	{inc='<ffi.h>', out='libffi.lua', final=function(code)
		code = removeWarnings(code)	-- LLONG_MIN
		code = [[
-- WARNING, this is libffi, not luajit ffi
-- will that make my stupid ?/?.lua LUA_PATH rule screw things up?  if so then move this file ... or rename it to libffi.lua or something
]] .. code .. [[
return ffi.load'ffi'
]]
		return code
	end},

	-- depends: stdbool.h
	-- apt install libgif-dev
	{inc='<gif_lib.h>', out='gif.lua', final=function(code)
		code = [[
-- gif 5.1.9
]] .. code .. [[
local gif
if ffi.os == 'OSX' then
	gif = ffi.load(os.getenv'LUAJIT_LIBPATH' .. '/bin/OSX/libgif.dylib')
elseif ffi.os == 'Windows' then
	gif = ffi.load(os.getenv'LUAJIT_LIBPATH' .. '/bin/Windows/' .. ffi.arch .. '/libgif1.dll')
elseif ffi.os == 'Linux' then
	gif = ffi.load'gif'
else
	gif = ffi.load(os.getenv'LUAJIT_LIBPATH' .. '/bin/linux/libgif.so')
end
return gif
]]
		return code
	end},

	{inc='<fitsio.h>', out='fitsio.lua', final=function(code)
		code = removeWarnings(code)	-- LLONG_MIN
		-- OFF_T is define'd to off_t soo ...
		code = code:gsub('enum { OFF_T = 0 };\n', '')
		code = code:gsub('OFF_T', 'off_t')
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'NULL')
		code = remove_need_macro(code, 'wchar_t')
		code = remove_need_macro(code, '__va_list')
		code = code .. [[
return ffi.load 'cfitsio'
]]
		return code
	end},

	-- apt install libnetcdf-dev
	{inc='<netcdf.h>', out='netcdf.lua', flags=string.trim(io.readproc'pkg-config --cflags netcdf'), final=function(code)
		code = code .. [[
return ffi.load'libnetcdf'
]]
		return code
	end},

	-- apt install libhdf5-dev
	-- depends: inttypes.h
	{inc='<hdf5.h>', out='hdf5.lua', flags=string.trim(io.readproc'pkg-config --cflags hdf5'), final=function(code)
		-- old header comment:
			-- for gcc / ubuntu looks like off_t is defined in either unistd.h or stdio.h, and either are set via testing/setting __off_t_defined
			-- in other words, the defs in here are getting more and more conditional ...
			-- pretty soon a full set of headers + full preprocessor might be necessary
			-- TODO regen this on Windows and compare?
		code = removeWarnings(code)	-- LLONG_MIN
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'NULL')
		code = remove_need_macro(code, '__va_list')
		code = code .. [[
--return ffi.load 'hdf5'	-- pkg-config --libs hdf5
return ffi.load('/usr/lib/x86_64-linux-gnu/hdf5/serial/libhdf5.so')
]]
		return code
	end},

	{
		flags = '-I../../cpp/ImGuiCommon/include -DCIMGUI_DEFINE_ENUMS_AND_STRUCTS',
		-- cimgui has these 3 files together:
		-- OpenGL i had to separate them
		-- and OpenGL i put them in OS-specific place
		inc = '"cimgui.h"',
		moreincs = {
			'"imgui_impl_sdl.h"',
			'"imgui_impl_opengl2.h"',
		},
		skipincs = {'"imgui.h"'},	-- full of C++ so don't include it
		out = 'cimgui.lua',
		final = function(code)
			-- this is already in SDL
			code = code:gsub(
				string.patescape'struct SDL_Window;'..'\n'
				..string.patescape'struct SDL_Renderer;'..'\n'
				..string.patescape'typedef union SDL_Event SDL_Event;',
				
				-- simultaneously insert require to ffi/sdl.lua
				"]] require 'ffi.sdl' ffi.cdef[["
			)
			code = remove_need_macro(code, 'size_t')
			code = remove_need_macro(code, 'NULL')
			code = remove_need_macro(code, '__va_list')

			code = code .. [[
return ffi.load'cimgui_sdl'
]]
			return code
		end,
	},

	{inc='<CL/cl.h>', moreincs={'<CL/cl_gl.h>'}, out='OpenCL.lua', final=function(code)
		code = commentOutLine(code, 'warning: Need to implement some method to align data here')
		
		-- ok because I have more than one inc, the second inc points back to the first, and so we do create a self-reference
		-- so fix it here:
		code = code:gsub(string.patescape"]] require 'ffi.OpenCL' ffi.cdef[[\n", "")
		
		code = code .. [[
local libs = ffi_OpenCL_libs or {
	OSX = {x86 = 'OpenCL.framework/OpenCL', x64 = 'OpenCL.framework/OpenCL'},
	Windows = {x86 = 'opencl.dll', x64 = 'opencl.dll'},
	Linux = {
	x86 = 'libOpenCL.so',
	x64 = 'libOpenCL.so',
	arm = 'bin/Linux/arm/libOpenCL.so'},
	BSD = {x86 = 'libOpenCL.so', x64 = 'libOpenCL.so'},
	POSIX = {x86 = 'libOpenCL.so', x64 = 'libOpenCL.so'},
	Other = {x86 = 'libOpenCL.so', x64 = 'libOpenCL.so'},
}
local lib = ffi_OpenCL_lib or libs[ffi.os][ffi.arch]
return ffi.load(lib)
]]
		return code
	end},

-- these external files are per-OS
-- maybe eventually all .h's will be?


	-- apt install libtiff-dev
	-- also per-OS
	-- depends: stddef.h stdint.h inttypes.h stdio.h stdarg.h
	{
		inc = '<tiffio.h>',
		out = 'Linux/tiff.lua',
		flags = string.trim(io.readproc'pkg-config --cflags libtiff-4'),
		final = function(code)
			code = remove_need_macro(code, 'size_t')
			code = remove_need_macro(code, 'NULL')
			code = remove_need_macro(code, '__va_list')
			return code
		end,
	},

	-- apt install libjpeg-turbo-dev
	-- linux is using 2.1.2 which generates no different than 2.0.3
	--  based on apt package libturbojpeg0-dev
	-- windows is using 2.0.4 just because 2.0.3 and cmake is breaking for msvc
	{inc='<jpeglib.h>', out='Linux/jpeg.lua', final=function(code)
		code = [[
require 'ffi.c.stdio'	-- for FILE, even though jpeglib.h itself never includes <stdio.h> ... hmm ...
]] .. code
		return code
	end},

	-- inc is put last before flags
	-- but inc is what the make_all.lua uses
	-- so this has to be built make_all.lua GL/glext.h
	-- but that wont work either cuz that will make the include to GL/glext.h into a split out file (maybe it should be?)
	-- for Windows I've got my glext.h outside the system paths, so you have to add that to the system path location.
	-- notice that GL/glext.h depends on GLenum to be defined.  but gl.h include glext.h.  why.
	{
		inc = '<GL/gl.h>',
		moreincs = {'<GL/glext.h>'},
		flags = '-DGL_GLEXT_PROTOTYPES',
		out = 'Linux/OpenGL.lua',
		final = function(code)
			code = code .. [[
return ffi.load'GL'
]]
			return code
		end,
	},

	{
		inc = '<lua.h>',
		moreincs = {'<lualib.h>', '<lauxlib.h>'},
		out = 'lua.lua',
		flags = string.trim(io.readproc'pkg-config --cflags lua'),
		final = function(code)
			code = removeWarnings(code)	-- LLONG_MIN
			code = remove_need_macro(code, 'size_t')
			code = remove_need_macro(code, 'NULL')
			code = remove_need_macro(code, '__va_list')
			code = [[
-- lua 5.4
]] .. code .. [[
local lua
if ffi.os == 'OSX' then
	lua = ffi.load(os.getenv'LUAJIT_LIBPATH' .. '/bin/OSX/liblua.dylib')
elseif ffi.os == 'Windows' then
	lua = ffi.load(os.getenv'LUAJIT_LIBPATH' .. '/bin/Windows/' .. ffi.arch .. '/liblua1.dll')
elseif ffi.os == 'Linux' then
	-- TODO pkg-config --libs lua ?
	lua = ffi.load'lua'
else
	lua = ffi.load(os.getenv'LUAJIT_LIBPATH' .. '/bin/linux/liblua.so')
end
return lua
]]
			return code
		end,
	},
	
	-- depends on limits.h
	-- because lua.ext uses some ffi stuff, it says "attempt to redefine 'dirent' at line 2"  for my load(file(...):read()) but not for require'results....'
	{
		inc = '<dirent.h>',
		out = 'c/dirent.lua',
		final = function(code)
			code = fixEnumsAndDefineMacrosInterleaved(code)
			return code
		end,
	},
	
	-- depends: sched.h time.h
	{inc='<pthread.h>', out='c/pthread.lua', final=function(code)
			code = fixEnumsAndDefineMacrosInterleaved(code)
			return code
	end},

	{inc='<sys/param.h>', out='c/sys/param.lua', final=function(code)
		-- warning for redefining LLONG_MIN or something
		code = removeWarnings(code)
		code = fixEnumsAndDefineMacrosInterleaved(code)
		-- i think all these stem from #define A B when the value is a string and not numeric
		--  but my #define to enum inserter forces something to be produced
		code = commentOutLine(code, 'enum { SIGIO = 0 };')
		code = commentOutLine(code, 'enum { SIGCLD = 0 };')
		code = commentOutLine(code, 'enum { SI_DETHREAD = 0 };')
		code = commentOutLine(code, 'enum { SI_TKILL = 0 };')
		code = commentOutLine(code, 'enum { SI_SIGIO = 0 };')
		code = commentOutLine(code, 'enum { SI_ASYNCIO = 0 };')
		code = commentOutLine(code, 'enum { SI_MESGQ = 0 };')
		code = commentOutLine(code, 'enum { SI_TIMER = 0 };')
		code = commentOutLine(code, 'enum { SI_QUEUE = 0 };')
		code = commentOutLine(code, 'enum { SI_USER = 0 };')
		code = commentOutLine(code, 'enum { SI_KERNEL = 0 };')
		code = commentOutLine(code, 'enum { __undef_ARG_MAX = 1 };')
		code = remove_need_macro(code, 'NULL')
		code = remove_need_macro(code, 'size_t')
		return code
	end},

	{inc='<sys/time.h>', out='c/sys/time.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'suseconds_t')
		code = fixEnumsAndDefineMacrosInterleaved(code)
		return code
	end},


	-- TODO
	-- uses a vararg macro which I don't support yet
--	{inc='<sys/sysinfo.h>', out='c/sys/sysinfo.lua'},

	-- depends on bits/libc-header-start
	-- '<identifier>' expected near '_Complex' at line 2
	-- has to do with enum/define'ing the builtin word _Complex
	{inc='<complex.h>', out='c/complex.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		code = commentOutLine(code, 'enum { _Complex = 0 };')
		code = commentOutLine(code, 'enum { complex = 0 };')
		code = commentOutLine(code, 'enum { _Mdouble_ = 0 };')
		
		-- this uses define<=>typedef which always has some trouble
		-- and this uses redefines which luajit ffi cant do so...
		-- TODO from
		--  /* # define _Mdouble_complex_ _Mdouble_ _Complex ### string, not number "_Mdouble_ _Complex" */
		-- to
		--  /* redefining matching value: #define _Mdouble_\t\tfloat */
		-- replace 	_Mdouble_complex_ with double _Complex
		-- from there to
		--  /* # define _Mdouble_       long double ### string, not number "long double" */
		-- replace _Mdouble_complex_ with float _Complex
		-- and from there until then end
		-- replace _Mdouble_complex_  with long double _Complex
		local a = code:find'_Mdouble_complex_ _Mdouble_ _Complex'
		local b = code:find'define _Mdouble_%s*float'
		local c = code:find'define _Mdouble_%s*long double'
		local parts = table{
			code:sub(1,a),
			code:sub(a+1,b),
			code:sub(b+1,c),
			code:sub(c+1),
		}
		parts[2] = parts[2]:gsub('_Mdouble_complex_', 'double _Complex')
		parts[3] = parts[3]:gsub('_Mdouble_complex_', 'float _Complex')
		parts[4] = parts[4]:gsub('_Mdouble_complex_', 'long double _Complex')
		code = parts:concat()

		return code
	end},
	
	-- depends on complex.h
	{inc='<cblas.h>', out='cblas.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		code = [[
]] .. code .. [[
local blas = ffi.load'openblas'
return blas
]]
		return code
	end},

	-- TODO preproc on this generate a *LOT* of `enum { LAPACK_lsame_base = 0 };`
	-- they are generated from macro calls to LAPACK_GLOBAL
	-- which is defined as
	-- #define LAPACK_GLOBAL(lcname,UCNAME)  lcname##_
	-- ... soo ... I need to not gen enums for macros that do string manipulation or whatever
	{inc='<lapack.h>', out='lapack.lua', final=function(code)
		code = code .. [[
local lapack = ffi.load'lapack'
return lapack
]]
		return code
	end},

	-- needs lapack_int replaced with int, except the enum def line
	{inc='<lapacke.h>', out='lapacke.lua', final=function(code)
		code = code .. [[
local lapacke = ffi.load'lapacke'
return lapacke
]]
		return code
	end},

	-- libzip-dev
	-- TODO #define ZIP_OPSYS_* is hex values, should be enums, but they are being commented out ...
	{inc='<zip.h>', out='zip.lua', final=function(code)
		code = code .. [[
local zip = ffi.load'zip'
return zip
]]
		return code
	end},

	-- produces an "int void" because macro arg-expansion covers already-expanded macro-args
	{inc='<png.h>', out='png.lua', final=function(code)
		-- warning for redefining LLONG_MIN or something
		code = removeWarnings(code)
		
		-- still working out macro bugs ... if macro expands arg A then I don't want it to expand arg B
		code = code:gsub('int void', 'int type');
		
		code = code .. [[
local png
if ffi.os == 'OSX' then
	png = ffi.load(os.getenv'LUAJIT_LIBPATH' .. '/bin/OSX/libpng.dylib')
elseif ffi.os == 'Windows' then
	png = ffi.load(os.getenv'LUAJIT_LIBPATH' .. '/bin/Windows/' .. ffi.arch .. '/png.dll')
elseif ffi.os == 'Linux' then
	png = ffi.load'png'
else
	png = ffi.load(os.getenv'LUAJIT_LIBPATH' .. '/bin/linux/libpng.so')
end
return png
]]
		return code
	end},

	-- TODO STILL
	-- looks like atm i'm using a hand-rolled sdl anyways
	{
		inc = '<SDL2/SDL.h>',
		out = 'sdl.lua',
		flags = string.trim(io.readproc'pkg-config --cflags sdl2'),
		final = function(code)
			-- warning: redefining __MATH_DECLARING_DOUBLE from 1 to 0 (originally 0)
			-- warning: redefining __MATH_DECLARING_FLOATN from 0 to 1 (originally 1)
			code = removeWarnings(code)
			code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
			-- TODO SDL includes wchar.h which defines WCHAR_MIN and WCHAR_MAX
			--  	and it includes bits/wchar.h which define __WCHAR_MIN and max
			-- but stdint includes only bits/wchar.h to define __WCHAR_MIN
			--	but stdint doesnt include wchar.h ... so WCHAR_MIN isnt defined
			-- but stdint does define WCHAR_MIN and max on its own ... why ... why doesn't it just include wchar.h?
			-- so hmm...
			
			code = code .. [[
local libs = ffi_luajit_libs or {
	OSX     = { x86 = "$LUAJIT_LIBPATH/bin/OSX/sdl.dylib", x64 = "$LUAJIT_LIBPATH/bin/OSX/sdl.dylib" },
	Windows = { x86 = "$LUAJIT_LIBPATH/bin/Windows/x86/SDL2.dll", x64 = "$LUAJIT_LIBPATH/bin/Windows/x64/SDL2.dll" },
	--Windows = { x86 = "$LUAJIT_LIBPATH/bin/Windows/x86/SDL.dll", x64 = "$LUAJIT_LIBPATH/bin/Windows/x64/SDL.dll" },
	Linux   = { },
	BSD     = { x86 = "bin/luajit32.so",  x64 = "bin/luajit64.so" },
	POSIX   = { x86 = "bin/luajit32.so",  x64 = "bin/luajit64.so" },
	Other   = { x86 = "bin/luajit32.so",  x64 = "bin/luajit64.so" },
}
local sdl  = ffi.load(
	(libs[ ffi.os ][ ffi.arch ] or "SDL2")
	:gsub('%$([_%w]+)', os.getenv)
)
return sdl
]]
			return code
		end,
	},

	{
		inc = '<ogg/ogg.h>',
		out = 'ogg/ogg.lua',
	},
	{
		inc = '<vorbis/codec.h>',
		out = 'vorbis/codec.lua',
	},
	{
		inc = '<vorbis/vorbisfile.h>',
		out = 'vorbis/vorbisfile.lua',
		flags = '-I/usr/include/vorbis',
		-- TODO the result contains some inline static functions and some static struct initializers which ffi cdef can't handle
	},
}

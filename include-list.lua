-- mapping from c includes to luajit ffi/ includes
-- this is used for automated generation
-- this is also used during generation for swapping out #includes with require()'s of already-generated files

local string = require 'ext.string'

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


return {
	{inc='stddef.h',		out='c/stddef.lua'},
	{inc='features.h',		out='c/features.lua'},
	{inc='bits/endian.h',	out='c/bits/endian.lua'},
	{inc='bits/types/locale_t.h',	out='c/bits/types/locale_t.lua'},
	{inc='bits/types/__sigset_t.h',	out='c/bits/types/__sigset_t.lua'},
	
	-- depends: features.h
	{inc='bits/floatn.h',	out='c/bits/floatn.lua'},	
	{inc='bits/types.h', out='c/bits/types.lua', final=function(code)
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
	{inc='bits/stdint-intn.h',	out='c/bits/stdint-intn.lua'},
	{inc='bits/types/clockid_t.h',	out='c/bits/types/clockid_t.lua'},
	{inc='bits/types/clock_t.h',	out='c/bits/types/clock_t.lua'},
	{inc='bits/types/struct_timeval.h',	out='c/bits/types/struct_timeval.lua'},
	{inc='bits/types/timer_t.h',	out='c/bits/types/timer_t.lua'},
	{inc='bits/types/time_t.h',	out='c/bits/types/time_t.lua'},

	-- depends: bits/types.h bits/endian.h
	{inc='bits/types/struct_timespec.h',	out='c/bits/types/struct_timespec.lua'},
	
	{inc='sys/ioctl.h', out='c/sys/ioctl.lua'},

	{inc='sys/select.h', out='c/sys/select.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'suseconds_t')
		return code
	end},

	-- depends: features.h bits/types.h
	-- mind you i found in the orig where it shouldve require'd features it was requiring itself ... hmm ...
	{inc='sys/termios.h',		out='c/sys/termios.lua'},

	-- depends: bits/types.h etc
	{inc='sys/stat.h', out='c/sys/stat.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'gid_t')
		code = replace_bits_types_builtin(code, 'uid_t')
		code = replace_bits_types_builtin(code, 'off_t')
		return code
	end},

	-- depends: features.h bits/types.h sys/select.h
	{inc='sys/types.h', out='c/sys/types.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'gid_t')
		code = replace_bits_types_builtin(code, 'uid_t')
		code = replace_bits_types_builtin(code, 'off_t')
		code = replace_bits_types_builtin(code, 'pid_t')
		code = replace_bits_types_builtin(code, 'ssize_t')
		code = remove_need_macro(code, 'size_t')
		return code
	end},

	-- depends: bits/libc-header-start.h
	-- with this the preproc gets a warning:
	--  warning: redefining LLONG_MIN from -1 to -9.2233720368548e+18 (originally (-LLONG_MAX - 1LL)) 
	-- and that comes with a giant can of worms of how i'm handling cdef numbers vs macro defs vs lua numbers ...
	-- mind you I could just make the warning: output into a comment 
	--  and there would be no need for manual manipulation here
	{inc='limits.h',		out='c/limits.lua', final=function(code)
		-- warning for redefining LLONG or something
		code = removeWarnings(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		return code
	end},

	-- depends: features.h sys/types.h
	{inc='stdlib.h', out='c/stdlib.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'wchar_t')
		code = remove_need_macro(code, 'NULL')
		return code
	end},
	
	-- depends: features.h, bits/types/__sigset_t.h
	{inc='setjmp.h',		out='c/setjmp.lua'},

	-- depends on features.h
	{inc='errno.h',		out='c/errno.lua', final=function(code)
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
	{inc='unistd.h',		out='c/unistd.lua', final=function(code)
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
	{inc='sched.h',		out='c/sched.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'pid_t')
		return code
	end},
	
	-- depends: bits/types.h
	{inc='stdint.h',	out='c/stdint.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		return code
	end},

	-- depends: features.h stddef.h bits/libc-header-start.h
	{inc='string.h', out='c/string.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'NULL')
		return code
	end},

	-- depends: features.h stddef.h bits/types.h and too many really
	-- this and any other file that requires stddef might have these lines which will have to be removed:
	{inc='time.h',		out='c/time.lua', final=function(code)
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'NULL')
		code = replace_bits_types_builtin(code, 'pid_t')
		return code
	end},

	-- depends on too much
	{inc='stdarg.h',		out='c/stdarg.lua', final=function(code)
		-- stdio.h and stdarg.h both define this
		-- typedef __gnuc_va_list va_list;
		-- enum { _VA_LIST_DEFINED = 1 };
		-- so maybe I should put it in its own manual file?
		code = remove_VA_LIST_DEFINED(code)
		code = replace_va_list_require(code)
		return code
	end},

	-- depends on too much
	{inc='stdio.h',	out='c/stdio.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		code = replace_bits_types_builtin(code, 'off_t')
		code = replace_bits_types_builtin(code, 'ssize_t')
		code = remove_need_macro(code, 'size_t')
		code = remove_need_macro(code, 'NULL')
		code = remove_VA_LIST_DEFINED(code)
		code = replace_va_list_require(code)
		-- this all stems from #define stdin stdin etc
		-- which itself is just for C99/C89 compat
		code = commentOutLine(code, 'enum { stdin = 0 };')
		code = commentOutLine(code, 'enum { stdout = 0 };')
		code = commentOutLine(code, 'enum { stderr = 0 };')
		return code
	end},

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
	{inc='bits/libc-header-start.h',	out='c/bits/libc-header-start.lua', final=function(code)
		return remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
	end},

	-- this is here for require() insertion but cannot be used for generation
	-- it must be manually extracted from c/setjmp.lua
	{inc='bits/setjmp.h',	out='c/bits/setjmp.lua'},

	-- stdio.h and stdarg.h both define va_list, so I put it here 
	{inc='va_list.h', out='c/va_list.lua'},


-- these come from external libraries (so I don't put them in the c/ subfolder)


	{inc='zlib.h',		out='zlib.lua', final=function(code)
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
	end},

}

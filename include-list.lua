-- mapping from c includes to luajit ffi/ includes
-- this is used for automated generation
-- this is also used during generation for swapping out #includes with require()'s of already-generated files

--[[
TODO an exhaustive way to generate all with the least # of intermediate files could be
- go down the list
- for each file, generate
- as you reach includes, see if any previous have requested the same include.
- if so then generate that include, and restart the process.
--]]

local ffi = require 'ffi'
local template = require 'template'
local string = require 'ext.string'
local table = require 'ext.table'
local io = require 'ext.io'
local tolua = require 'ext.tolua'

-- TODO for all these .final() functions,
-- wrap them in a function that detects if the modification took place, and writes a warning to stderr if it didn't.
-- that way as versions increment I can know which filters are no longer needed.

local function remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
	return (code:gsub('enum { __GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION = 1 };\n', ''))
end

-- TODO maybe ffi.Linux.c.bits.types instead
-- pid_t and pid_t_defined are manually inserted into lots of dif files
-- i've separated it into its own file myself, so it has to be manually replaced
-- same is true for a few other types
local function replace_bits_types_builtin(code, ctype)
	code = code:gsub(string.patescape([[
typedef __]]..ctype..[[ ]]..ctype..[[;
enum { __]]..ctype..[[_defined = 1 };]]),
		[=[]] require 'ffi.req' 'c.bits.types.]=]..ctype..[=[' ffi.cdef[[]=]
	)
	return code
end

local function remove_need_macro(code)
	code = code:gsub('enum { __need_[_%w]* = 1 };\n', '')
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
		[=[]] require 'ffi.req' 'c.va_list' ffi.cdef[[]=]
	)
	return code
end

-- unistd.h and stdio.h both define SEEK_*, so ...
local function replace_SEEK(code)
		return code:gsub([[
enum { SEEK_SET = 0 };
enum { SEEK_CUR = 1 };
enum { SEEK_END = 2 };
]], "]] require 'ffi.req' 'c.bits.types.SEEK' ffi.cdef[[\n")
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

-- ok with {.-} it fails on funcntions that have {}'s in their body, like wmemset
-- so lets try %b{}
-- TODO name might have a * before it instead of a space...
local function removeStaticFunction(code, name)
	return code:gsub('static%s[^(]-%s'..name..'%s*%(.-%)%s*%b{}', '')
end

local function removeInlineFunction(code, name)
	return code:gsub('__inline%s[^(]-%s'..name..'%s*%(.-%)%s*%b{}', '')
end

local function removeDeclSpecNoInlineFunction(code, name)
	return code:gsub('__declspec%(noinline%)%s*__inline%s[^(]-%s'..name..'%s*%(.-%)%s*%b{}', '')
end


local includeList = table()

-- files found in multiple OS's will go in [os]/[path]
-- and then in just [path] will be a file that determines the file based on os (and arch?)

-- [====[ Begin Windows-specific:
-- TODO this is most likely going to be come Windows/x64/ files in the future
includeList:append(table{

-- Windows-only:
	{inc='<corecrt.h>', out='Windows/c/corecrt.lua'},

	{inc='<corecrt_share.h>', out='Windows/c/corecrt_share.lua'},

	{inc='<corecrt_wdirect.h>', out='Windows/c/corecrt_wdirect.lua'},

	{inc='<corecrt_wstdio.h>', out='Windows/c/corecrt_wstdio.lua'},

	{
		inc = '<corecrt_stdio_config.h>',
		out = 'Windows/c/corecrt_stdio_config.lua',
		final = function(code)
			for _,f in ipairs{
				'__local_stdio_printf_options',
				'__local_stdio_scanf_options',
			} do
				code = removeInlineFunction(code, f)
			end
			return code
		end,
	},

	-- uses corecrt_share.h
	{
		inc = '<corecrt_wio.h>',
		out = 'Windows/c/corecrt_wio.lua',
		final = function(code)
			code = code:gsub('enum { _wfinddata_t = 0 };', '')
			code = code:gsub('enum { _wfinddatai64_t = 0 };', '')
			return code
		end,
	},

	{inc='<corecrt_wstring.h>', out='Windows/c/corecrt_wstring.lua'},

	{inc='<corecrt_wstdlib.h>', out='Windows/c/corecrt_wstdlib.lua'},
	{inc='<corecrt_wtime.h>', out='Windows/c/corecrt_wtime.lua'},

-- cross support (so an intermediate ffi.c.stddef is needed for redirecting based on OS
	{inc='<stddef.h>', out='Windows/c/stddef.lua'},

	-- depends on: corecrt_wtime.h
	{
		inc = '<time.h>',
		out = 'Windows/c/time.lua',
		final = function(code)
			code = removeStaticFunction(code, '_wctime')
			code = removeStaticFunction(code, '_wctime_s')
			code = removeStaticFunction(code, 'ctime')
			code = removeStaticFunction(code, 'difftime')
			code = removeStaticFunction(code, 'gmtime')
			code = removeStaticFunction(code, 'localtime')
			code = removeStaticFunction(code, '_mkgmtime')
			code = removeStaticFunction(code, 'mktime')
			code = removeStaticFunction(code, 'time')
			code = removeStaticFunction(code, 'timespec_get')
			-- add these static inline wrappers as lua wrappers
			code = code .. [[
return setmetatable({
	_wctime = ffi.C._wctime64,
	_wctime_s = ffi.C._wctime64_s,
	ctime = _ctime64,
	difftime = _difftime64,
	gmtime = _gmtime64,
	localtime = _localtime64,
	_mkgmtime = _mkgmtime64,
	mktime = _mktime64,
	time = _time64,
	timespec_get = _timespec_get64,
}, {
	__index = ffi.C,
})
]]
			return code
		end,
	},

	{
		inc = '<sys/types.h>',
		out = 'Windows/c/sys/types.lua',
		final = function(code)
			code = code .. [=[

-- this isn't in Windows at all I guess, but for cross-platform's sake, I'll put in some common POSIX defs I need
-- gcc x64 defines ssize_t = __ssize_t, __ssize_t = long int
-- I'm guessing in gcc 'long int' is 8 bytes
-- msvc x64 'long int' is just 4 bytes ...
-- TODO proly arch-specific too

ffi.cdef[[
typedef intptr_t ssize_t;
]]
]=]
			return code
		end,
	},

	{
		inc = '<errno.h>',
		out = 'Windows/c/errno.lua',
	},

	-- depends on: errno.h corecrt_wstring.h
	{
		inc = '<string.h>',
		out = 'Windows/c/string.lua',
		-- TODO final() that outputs a wrapper that replaces calls to all the default POSIX functions with instead calls to the alternative safe ones
		final = function(code)
			code = removeStaticFunction(code, '_wcstok')
			return code
		end,
	},

	-- depends on: corecrt_wio.h, corecrt_share.h
	-- really it just includes corecrt_io.h
	{
		inc = '<io.h>',
		out = 'Windows/c/io.lua',
		final = function(code)
			code = code:gsub('enum { _finddata_t = 0 };', '')
			code = code:gsub('enum { _finddatai64_t = 0 };', '')

			-- same as in corecrt_wio.h
			code = code .. [=[
ffi.cdef[[
/* #ifdef _USE_32BIT_TIME_T
	typedef _finddata32_t _finddata_t;
	typedef _finddata32i64_t _finddatai64_t;
#else */
	typedef struct _finddata64i32_t _finddata_t;
	typedef struct _finddata64_t _finddatai64_t;
/* #endif */
]]

local lib = ffi.C
return setmetatable({
--[[
#ifdef _USE_32BIT_TIME_T
	_findfirst = lib._findfirst32,
	_findnext = lib._findnext32,
	_findfirsti64 = lib._findfirst32i64,
	_findnexti64 = lib._findnext32i64,
#else
--]]
	_findfirst = lib._findfirst64i32,
	_findnext = lib._findnext64i32,
	_findfirsti64 = lib._findfirst64,
	_findnexti64 = lib._findnext64,
--[[
#endif
--]]
}, {
	__index = ffi.C,
})
]=]
			return code
		end,
	},

	-- depends on: errno.h corecrt_wio.h corecrt_wstring.h corecrt_wdirect.h corecrt_stdio_config.h corecrt_wtime.h
	{
		inc = '<wchar.h>',
		out = 'Windows/c/wchar.lua',
		final = function(code)
			code = removeDeclSpecNoInlineFunction(code, '__local_stdio_printf_options')
			code = removeDeclSpecNoInlineFunction(code, '__local_stdio_scanf_options')
			for _,f in ipairs{
				'_vcwprintf_l',
				'_vcwprintf',
				'_vcwprintf_s_l',
				'_vcwprintf_s',
				'_vcwprintf_p_l',
				'_vcwprintf_p',
				'_cwprintf_l',
				'_cwprintf',
				'_cwprintf_s_l',
				'_cwprintf_s',
				'_cwprintf_p_l',
				'_cwprintf_p',
				'_vcwscanf_l',
				'_vcwscanf',
				'_vcwscanf_s_l',
				'_vcwscanf_s',
				'_cwscanf_l',
				'_cwscanf',
				'_cwscanf_s_l',
				'_cwscanf_s',
				'_vfwprintf_l',
				'vfwprintf',
				'_vfwprintf_s_l',
				'_vfwprintf_p_l',
				'_vfwprintf_p',
				'_vwprintf_l',
				'vwprintf',
				'_vwprintf_s_l',
				'_vwprintf_p_l',
				'_vwprintf_p',
				'_fwprintf_l',
				'fwprintf',
				'_fwprintf_s_l',
				'_fwprintf_p_l',
				'_fwprintf_p',
				'_wprintf_l',
				'wprintf',
				'_wprintf_s_l',
				'_wprintf_p_l',
				'_wprintf_p',
				'_vfwscanf_l',
				'vfwscanf',
				'_vfwscanf_s_l',
				'_vwscanf_l',
				'vwscanf',
				'_vwscanf_s_l',
				'_fwscanf_l',
				'fwscanf',
				'_fwscanf_s_l',
				'_wscanf_l',
				'wscanf',
				'_wscanf_s_l',
				'_vsnwprintf_l',
				'_vsnwprintf_s_l',
				'_vsnwprintf_s',
				'_vsnwprintf',
				'_vswprintf_c_l',
				'_vswprintf_c',
				'_vswprintf_l',
				'__vswprintf_l',
				'_vswprintf',
				'vswprintf',
				'_vswprintf_s_l',
				'_vswprintf_p_l',
				'_vswprintf_p',
				'_vscwprintf_l',
				'_vscwprintf',
				'_vscwprintf_p_l',
				'_vscwprintf_p',
				'__swprintf_l',
				'_swprintf_l',
				'_swprintf',
				'swprintf',
				'_swprintf_s_l',
				'_swprintf_p_l',
				'_swprintf_p',
				'_swprintf_c_l',
				'_swprintf_c',
				'_snwprintf_l',
				'_snwprintf',
				'_snwprintf_s_l',
				'_snwprintf_s',
				'_scwprintf_l',
				'_scwprintf',
				'_scwprintf_p_l',
				'_scwprintf_p',
				'_vswscanf_l',
				'vswscanf',
				'_vswscanf_s_l',
				'_vsnwscanf_l',
				'_vsnwscanf_s_l',
				'_swscanf_l',
				'swscanf',
				'_swscanf_s_l',
				'_snwscanf_l',
				'_snwscanf',
				'_snwscanf_s_l',
				'_snwscanf_s',
				'fwide',
				'mbsinit',
				'wmemchr',
				'wmemcmp',
				'wmemcpy',
				'wmemmove',
				'wmemset',
			} do
				code = removeInlineFunction(code, f)
			end
			for _,f in ipairs{
				'_wcstok',
				'_wctime',
				'_wctime_s',
			} do
				code = removeStaticFunction(code, f)
			end

			-- corecrt_wio.h #define's types that I need, so typedef them here instead
			-- TODO pick according to the current macros
			-- but make_all.lua and generate.lua run in  separate processes, so ....
			code = code .. [=[
ffi.cdef[[
/* #ifdef _USE_32BIT_TIME_T
	typedef _wfinddata32_t _wfinddata_t;
	typedef _wfinddata32i64_t _wfinddatai64_t;
#else */
	typedef struct _wfinddata64i32_t _wfinddata_t;
	typedef struct _wfinddata64_t _wfinddatai64_t;
/* #endif */
]]

local lib = ffi.C
return setmetatable({
--[[
#ifdef _USE_32BIT_TIME_T
	_wfindfirst = lib._wfindfirst32,
	_wfindnext = lib._wfindnext32,
	_wfindfirsti64 = lib._wfindfirst32i64,
	_wfindnexti64 = lib._wfindnext32i64,
#else
--]]
	_wfindfirst = lib._wfindfirst64i32,
	_wfindnext = lib._wfindnext64i32,
	_wfindfirsti64 = lib._wfindfirst64,
	_wfindnexti64 = lib._wfindnext64,
--[[
#endif
--]]
}, {
	__index = ffi.C,
})
]=]
			return code
		end,
	},

	-- depends: corecrt_wdirect.h
	-- was a Windows programmer trying to type "dirent.h" and got mixed up?
	-- looks like a few of these functions are usually in POSIX unistd.h
	{
		inc = '<direct.h>',
		out = 'Windows/c/direct.lua',
	},

	-- depends: corecrt_stdio_config.h
	{
		inc = '<stdio.h>',
		out = 'Windows/c/stdio.lua',
		final = function(code)
			-- TODO some of these look useful.
			-- that means I'll have to re-add the mapping in final()
			for _,f in ipairs{
				'_vfprintf_l',
				'vfprintf',
				'_vfprintf_s_l',
				'_vfprintf_p_l',
				'_vfprintf_p',
				'_vprintf_l',
				'vprintf',
				'_vprintf_s_l',
				'_vprintf_p_l',
				'_vprintf_p',
				'_fprintf_l',
				'fprintf',
				'_fprintf_s_l',
				'_fprintf_p_l',
				'_fprintf_p',
				'_printf_l',
				'printf',
				'_printf_s_l',
				'_printf_p_l',
				'_printf_p',
				'_vfscanf_l',
				'vfscanf',
				'_vfscanf_s_l',
				'_vscanf_l',
				'vscanf',
				'_vscanf_s_l',
				'_fscanf_l',
				'fscanf',
				'_fscanf_s_l',
				'_scanf_l',
				'scanf',
				'_scanf_s_l',
				'_vsnprintf_l',
				'_vsnprintf',
				'vsnprintf',
				'_vsprintf_l',
				'vsprintf',
				'_vsprintf_s_l',
				'_vsprintf_p_l',
				'_vsprintf_p',
				'_vsnprintf_s_l',
				'_vsnprintf_s',
				'_vscprintf_l',
				'_vscprintf',
				'_vscprintf_p_l',
				'_vscprintf_p',
				'_vsnprintf_c_l',
				'_vsnprintf_c',
				'_sprintf_l',
				'sprintf',
				'_sprintf_s_l',
				'_sprintf_p_l',
				'_sprintf_p',
				'_snprintf_l',
				'snprintf',
				'_snprintf',
				'_snprintf_c_l',
				'_snprintf_c',
				'_snprintf_s_l',
				'_snprintf_s',
				'_scprintf_l',
				'_scprintf',
				'_scprintf_p_l',
				'_scprintf_p',
				'_vsscanf_l',
				'vsscanf',
				'_vsscanf_s_l',
				'_sscanf_l',
				'sscanf',
				'_sscanf_s_l',
				'_snscanf_l',
				'_snscanf',
				'_snscanf_s_l',
				'_snscanf_s',
			} do
				code = removeInlineFunction(code, f)
			end
			-- return ffi.C so it has the same return behavior as Linux/c/stdio
			code = code .. [[
local lib = ffi.C
return setmetatable({
	fileno = lib._fileno,
}, {
	__index = ffi.C,
})
]]
		end,
	},

	-- depends: sys/types.h
	{
		inc = '<sys/stat.h>',
		out = 'Windows/c/sys/stat.lua',
		final = function(code)
			-- remove the #define-as-typedef produced enums...
			for _,f in ipairs{
				'__stat64',
				'_fstat',
				'_fstati64',
				'_stat',
				'_stati64',
				'_wstat',
				'_wstati64',
			} do
				code = code:gsub('enum { '..f..' = 0 };', '')
			end

			code = removeStaticFunction(code, 'fstat')	-- _fstat64i32
			code = removeStaticFunction(code, 'stat')	-- _stat64i32

			-- windows help says "always include sys/types.h first"
			-- ... smh why couldn't they just include it themselves?
			code = [[
require 'ffi.req' 'c.sys.types'
]] .. code
			code = code .. [=[
ffi.cdef[[
typedef struct _stat64 __stat64;
]]

-- for linux mkdir compat
require 'ffi.Windows.c.direct'

local lib = ffi.C
return setmetatable({
--[[
#ifdef _USE_32BIT_TIME_T
	_fstat = lib._fstat32,
	_fstati64 = lib._fstat32i64,

	_wstat = lib._wstat32,
	_wstati64 = lib._wstat32i64,
	-- header inline function Lua alias:
	--fstat = lib._fstat32,
	--stat = lib._stat32,

	--_stat = lib._stat32,
	--struct_stat = 'struct _stat32',
	--_stati64 = lib._stat32i64,
	--struct_stat64 = 'struct _stat32i64',

	-- for lfs compat:
	fstat = lib._fstat32,
	stat = lib._stat32,
	stat_struct = 'struct _stat32',
#else
--]]
	_fstat = lib._fstat64i32,
	_fstati64 = lib._fstat64,

	_wstat = lib._wstat64i32,
	_wstati64 = lib._wstat64,
	-- header inline function Lua alias:
	--fstat = lib._fstat64i32,
	--stat = lib._stat64i32,
	--_stat = lib._stat64i32,
	--struct_stat = 'struct _stat64i32', -- this is the 'struct' that goes with the 'stat' function ...
	--_stati64 = lib._stat64,
	--struct_stat64 = 'struct _stat64',

	-- but I think I want 'stat' to point to '_stat64'
	-- and 'struct_stat' to point to 'struct _stat64'
	-- for lfs_ffi compat between Linux and Windows
	fstat = lib._fstat64,
	stat = lib._stat64,
	struct_stat = 'struct _stat64',
--[[
#endif
--]]
}, {
	__index = ffi.C,
})
]=]
			return code
		end,
	},

	-- windows says ...
	-- _utime, _utime32, _utime64 is in sys/utime.h
	-- _wutime is in utime.h or wchar.h (everything is in wchar.h ...)
	-- posix says ...
	-- utime is in utime.h
	-- utimes is in sys/time.h
	-- ... could windows play ball and let utime.h redirect to sys/utime.h?
	-- ... nope. just sys/utime.h
	-- so let me check posix for sys/utime.h, if it doesn't exist then maybe I'll consider renaming this to utime.h instead of sys/utime.h
	-- nope it doesn't
	-- so instead I think I'll have ffi.c.utime and ffi.c.sys.utime point to windows' ffi.windows.c.sys.utime or linux' ffi.linux.c.utime
	{
		inc = '<sys/utime.h>',
		out = 'Windows/c/sys/utime.lua',
		-- TODO custom split file that redirects to Windows -> sys.utime, Linux -> utime
		final = function(code)
			for _,f in ipairs{
				'_utime',
				'_futime',
				'_wutime',
				'utime',
			} do
				code = removeStaticFunction(code, f)
			end
			code = code .. [=[
local lib = ffi.C
return setmetatable(
ffi.arch == 'x86' and {
	utime = lib._utime32,
	struct_utimbuf = 'struct __utimbuf32',
} or {
	utime = lib._utime64,
	struct_utimbuf = 'struct __utimbuf64'
}, {
	__index = lib,
})
]=]
			return code
		end,
	},

	-- unless I enable _VCRT_COMPILER_PREPROCESSOR , this file is empty
	-- maybe it shows up elsewhere?
	-- hmm but if I do, my preproc misses almost all the number defs
	-- becaus they use suffixes i8, i16, i32, i64, ui8, ui16, ui32, ui64
	-- but the types it added ... int8_t ... etc ... are alrady buitin to luajit?
	{
		inc = '<stdint.h>',
		out = 'Windows/c/stdint.lua',
	},

	{
		inc = '<stdarg.h>',
		out = 'Windows/c/stdarg.lua',
	},

	-- identical in windows and linux ...
	{
		inc = '<stdbool.h>',
		out = 'Windows/c/stdbool.lua',
		final = function(code)
			-- luajit has its own bools already defined
			code = commentOutLine(code, 'enum { bool = 0 };')
			code = commentOutLine(code, 'enum { true = 1 };')
			code = commentOutLine(code, 'enum { false = 0 };')
			return code
		end
	},

	{
		inc = '<limits.h>',
		out = 'Windows/c/limits.lua',
	},

	-- depends: corecrt_wstdlib.h limits.h
	{
		inc = '<stdlib.h>',
		out = 'Windows/c/stdlib.lua',
	},
	
	-- needed by png.h
	{inc='<setjmp.h>', out='Windows/c/setjmp.lua'},

	-- not in windows, but I have a fake for aliasing, so meh
	{
		inc = '<unistd.h>',
		out = 'Windows/c/unistd.lua',
		forcecode = [=[
local ffi = require 'ffi'
require 'ffi.Windows.c.direct'  -- get our windows defs
local lib = ffi.C
-- TODO I see the orig name prototypes in direct.h ...
-- ... so do I even need the Lua alias anymore?
return setmetatable({
	chdir = lib._chdir,
	getcwd = lib._getcwd,
	rmdir = lib._rmdir,
}, {
	__index = lib,
})
]=]
	},

}:mapi(function(inc)
	inc.os = 'Windows'
	return inc
end))
--]====]

-- [====[ Begin Linux-specific:
includeList:append(table{

	{inc='<stddef.h>', out='Linux/c/stddef.lua'},

	{inc='<bits/wordsize.h>', out='Linux/c/bits/wordsize.lua'},

	-- depends: bits/wordsize.h
	{inc='<features.h>', out='Linux/c/features.lua'},

	{inc='<bits/endian.h>',	out='Linux/c/bits/endian.lua'},
	{inc='<bits/types/locale_t.h>',	out='Linux/c/bits/types/locale_t.lua'},
	{inc='<bits/types/__sigset_t.h>',	out='Linux/c/bits/types/__sigset_t.lua'},

	{inc='<bits/wchar.h>', out='Linux/c/bits/wchar.lua'},

	-- depends: features.h
	{
		inc = '<bits/floatn.h>',
		out = 'Linux/c/bits/floatn.lua',
		final = function(code)
			-- luajit doesn't handle float128 ...
			--code = code:gsub('(128[_%w]*) = 1', '%1 = 0')
			return code
		end,
	},

	{inc='<bits/types.h>', out='Linux/c/bits/types.lua', final=function(code)
		-- manually:
		-- `enum { __FD_SETSIZE = 1024 };`
		-- has to be replaced with
		-- `]] require 'ffi.req' 'c.__FD_SETSIZE' ffi.cdef[[`
		-- because it's a macro that appears in a few places, so I manually define it.
		-- (and maybe also write the file?)
		return (code:gsub(
			'enum { __FD_SETSIZE = 1024 };',
			[=[]] require 'ffi.req' 'c.__FD_SETSIZE' ffi.cdef[[]=]
		))
	end},

	-- depends: bits/types.h
	{inc='<bits/stdint-intn.h>',	out='Linux/c/bits/stdint-intn.lua'},
	{inc='<bits/types/clockid_t.h>',	out='Linux/c/bits/types/clockid_t.lua'},
	{inc='<bits/types/clock_t.h>',	out='Linux/c/bits/types/clock_t.lua'},
	{inc='<bits/types/struct_timeval.h>',	out='Linux/c/bits/types/struct_timeval.lua'},
	{inc='<bits/types/timer_t.h>',	out='Linux/c/bits/types/timer_t.lua'},
	{inc='<bits/types/time_t.h>',	out='Linux/c/bits/types/time_t.lua'},

	-- depends: bits/types.h bits/endian.h
	{inc='<bits/types/struct_timespec.h>',	out='Linux/c/bits/types/struct_timespec.lua'},

	{inc='<sys/ioctl.h>', out='Linux/c/sys/ioctl.lua'},

	{inc='<sys/select.h>', out='Linux/c/sys/select.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'suseconds_t')
		return code
	end},

	-- depends: features.h bits/types.h
	-- mind you i found in the orig where it shouldve require'd features it was requiring itself ... hmm ...
	{inc='<sys/termios.h>', out='Linux/c/sys/termios.lua'},

	-- depends: features.h bits/types.h sys/select.h
	{inc='<sys/types.h>', out='Linux/c/sys/types.lua', final=function(code)
		for _,t in ipairs{
			'dev_t',
			'ino_t',
			'mode_t',
			'nlink_t',
			'gid_t',
			'uid_t',
			'off_t',
			'pid_t',
			'ssize_t',
		} do
			code = replace_bits_types_builtin(code, t)
		end
		code = remove_need_macro(code)
		return code
	end},

	{inc='<linux/limits.h>', out='Linux/c/linux/limits.lua', final=function(code)
		code = commentOutLine(code, 'enum { __undef_ARG_MAX = 1 };')
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
	{dontGen=true, inc='<bits/libc-header-start.h>', out='Linux/c/bits/libc-header-start.lua', final=function(code)
		return remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
	end},

	-- depends: features.h stddef.h bits/libc-header-start.h
	{inc='<string.h>', out='Linux/c/string.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		code = remove_need_macro(code)
		return code
	end},

	-- depends: features.h stddef.h bits/types.h and too many really
	-- this and any other file that requires stddef might have these lines which will have to be removed:
	{
		inc = '<time.h>',
		out = 'Linux/c/time.lua',
		final = function(code)
			code = remove_need_macro(code)
			code = replace_bits_types_builtin(code, 'pid_t')
			return code
		end,
	},

	-- depends on features.h
	{
		inc = '<errno.h>',
		out = 'Linux/c/errno.lua',
		final = function(code)
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
		end,
	},

	{
		inc = '<utime.h>',
		out = 'Linux/c/utime.lua',
		final = function(code)
			code = code .. [[
return setmetatable({
	struct_utimbuf = 'struct utimbuf',
}, {
	__index = ffi.C,
})
]]
			return code
		end,
	},

	-- depends: bits/types.h etc
	{inc='<sys/stat.h>', out='Linux/c/sys/stat.lua', final=function(code)
		for _,t in ipairs{
			'dev_t',
			'ino_t',
			'mode_t',
			'nlink_t',
			'gid_t',
			'uid_t',
			'off_t',
		} do
			code = replace_bits_types_builtin(code, t)
		end
		code = code .. [[
local lib = ffi.C
return setmetatable({
	struct_stat = 'struct stat',
}, {
	__index = lib,
})
]]
		return code
	end},

	-- depends: bits/types.h
	{
		inc = '<stdint.h>',
		out = 'Linux/c/stdint.lua',
		final = function(code)
			code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)

			--code = replace_bits_types_builtin(code, 'intptr_t')
			-- not the same def ...
			code = code:gsub([[
typedef long int intptr_t;
enum { __intptr_t_defined = 1 };
]], [=[]] require 'ffi.req' 'c.bits.types.intptr_t' ffi.cdef[[]=])


			-- error: `attempt to redefine 'WCHAR_MIN' at line 75
			-- because it's already in <wchar.h>
			-- comment in stdint.h:
			-- "These constants might also be defined in <wchar.h>."
			-- yes. yes they are.
			-- so how to fix this ...
			-- looks like wchar.h doesn't include stdint.h...
			-- and stdint.h includes bits/wchar.h but not wchar.h
			-- and yeah the macros are in wchar.h, not bits/whcar.h
			-- hmm ...
			code = code:gsub(string.patescape[[
enum { WCHAR_MIN = -2147483648 };
enum { WCHAR_MAX = 2147483647 };
]], [=[]] require 'ffi.req' 'c.wchar' ffi.cdef[[]=])

			return code
		end,
	},

	-- depends: features.h sys/types.h
	{
		inc = '<stdlib.h>',
		out = 'Linux/c/stdlib.lua',
		final = function(code)
			code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
			code = remove_need_macro(code)
			return code
		end,
	},

	{
		inc = '<bits/types/__mbstate_t.h>',
		out = 'Linux/c/bits/types/__mbstate_t.lua',
	},
	{
		inc = '<bits/types/__FILE.h>',
		out = 'Linux/c/bits/types/__FILE.lua',
	},
	{
		inc = '<bits/types/FILE.h>',
		out = 'Linux/c/bits/types/FILE.lua',
	},

	-- depends on: bits/types/__mbstate_t.h
	-- I never needed it in Linux, until I got to SDL
	{
		inc = '<wchar.h>',
		out = 'Linux/c/wchar.lua',
		final = function(code)
			code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
			code = remove_need_macro(code)
			return code
		end,
	},

	-- depends: bits/wordsize.h
	{
		inc = '<bits/posix1_lim.h>',
		out = 'Linux/c/bits/posix1_lim.lua',
	},

	-- depends: bits/libc-header-start.h linux/limits.h bits/posix1_lim.h
	-- with this the preproc gets a warning:
	--  warning: redefining LLONG_MIN from -1 to -9.2233720368548e+18 (originally (-LLONG_MAX - 1LL))
	-- and that comes with a giant can of worms of how i'm handling cdef numbers vs macro defs vs lua numbers ...
	-- mind you I could just make the warning: output into a comment
	--  and there would be no need for manual manipulation here
	{inc='<limits.h>', out='Linux/c/limits.lua', final=function(code)
		-- warning for redefining LLONG or something
		code = removeWarnings(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		return code
	end},

	-- depends: features.h, bits/types/__sigset_t.h
	{inc='<setjmp.h>', out='Linux/c/setjmp.lua'},

	-- depends: features.h bits/types.h
	{
		inc = '<unistd.h>',
		out = 'Linux/c/unistd.lua',
		final = function(code)
			for _,t in ipairs{
				'gid_t',
				'uid_t',
				'off_t',
				'pid_t',
				'ssize_t',
				'intptr_t',
			} do
				code = replace_bits_types_builtin(code, t)
			end
			code = remove_need_macro(code)

			-- both unistd.h and stdio.h have SEEK_* defined, so ...
			-- you'll have to manually create this file
			code = replace_SEEK(code)

			-- there are a few enums defined, and then #define'd, and preproc leaves an enum = 0, so make sure the latter is removed
			-- [[ look for specific prefix of enum = 0
			code = code:gsub('enum { _PC_[%w_]+ = 0 };', '')
			code = code:gsub('enum { _SC_[%w_]+ = 0 };', '')
			code = code:gsub('enum { _CS_[%w_]+ = 0 };', '')
			--]]
			--[[ would be nice to remove automatically
			code = code:gsub('([%w_]+)(,?) enum { ([%w_]+) = 0 };', function(a,b,c)
				if a == c then return a..b else return '%0' end
			end)
			--]]

			code = code:gsub(
				-- TODO i'm sure this dir will change in the future ...
				string.patescape('/* BEGIN /usr/include/x86_64-linux-gnu/bits/confname.h */')
				..'.*'
				..string.patescape('/* END   /usr/include/x86_64-linux-gnu/bits/confname.h */'),
				[[

/* TODO here I skipped conframe because it was too many mixed enums and ddefines => enums */
]]
			)
--[=[ TODO this goes in the manually-created split file in ffi.c.unistd
			code = code .. [[
-- I can't change ffi.C.getcwd to ffi.C._getcwd in the case of Windows
local lib = ffi.C
if ffi.os == 'Windows' then
	require 'ffi.req' 'c.direct'	-- get our windows defs
	return setmetatable({
		chdir = lib._chdir,
		getcwd = lib._getcwd,
		rmdir = lib._rmdir,
	}, {
		__index = lib,
	})
else
	return lib
end
]]
--]=]
			-- but for interchangeability with Windows ...
			code = code .. [[
return ffi.C
]]
			return code
		end,
	},

	-- depends: stddef.h bits/types/time_t.h bits/types/struct_timespec.h
	{inc='<sched.h>', out='Linux/c/sched.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'pid_t')
		code = remove_need_macro(code)
		return code
	end},

	-- depends on too much
	{inc='<stdarg.h>', out='Linux/c/stdarg.lua', final=function(code)
		-- stdio.h and stdarg.h both define this
		-- typedef __gnuc_va_list va_list;
		-- enum { _VA_LIST_DEFINED = 1 };
		-- so maybe I should put it in its own manual file?
		code = remove_VA_LIST_DEFINED(code)
		code = replace_va_list_require(code)
		return code
	end},

	-- identical in windows and linux ...
	{inc='<stdbool.h>', out='Linux/c/stdbool.lua', final=function(code)
		-- luajit has its own bools already defined
		code = commentOutLine(code, 'enum { bool = 0 };')
		code = commentOutLine(code, 'enum { true = 1 };')
		code = commentOutLine(code, 'enum { false = 0 };')
		return code
	end},

	-- depends: features.h stdint.h
	{inc='<inttypes.h>', out='Linux/c/inttypes.lua'},

	-- depends on too much
	-- moving to Linux-only block since now it is ...
	-- it used to be just after stdarg.h ...
	-- maybe I have to move everything up to that file into the Linux-only block too ...
	{
		inc = '<stdio.h>',
		out = 'Linux/c/stdio.lua',
		final = function(code)
			code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
			code = replace_bits_types_builtin(code, 'off_t')
			code = replace_bits_types_builtin(code, 'ssize_t')
			code = remove_need_macro(code)
			code = remove_VA_LIST_DEFINED(code)
			code = replace_va_list_require(code)
			-- this is in stdio.h and unistd.h
			code = replace_SEEK(code)
			-- this all stems from #define stdin stdin etc
			-- which itself is just for C99/C89 compat
			code = commentOutLine(code, 'enum { stdin = 0 };')
			code = commentOutLine(code, 'enum { stdout = 0 };')
			code = commentOutLine(code, 'enum { stderr = 0 };')
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
		end,
	},

	{
		inc = '<math.h>',
		out = 'Linux/c/math.lua',
		final = function(code)
			code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
			code = code:gsub('enum { __MATH_DECLARING_DOUBLE = %d+ };', '')
			code = code:gsub('enum { __MATH_DECLARING_FLOATN = %d+ };', '')

			-- [[ enums and #defines intermixed ... smh
			code = code:gsub(' ([_%a][_%w]*) = enum { ([_%a][_%w]*) = %d+ };', function(a,b)
				if a == b then return ' '..a..' = ' end
				return '%0'
			end)
			--]]

			-- gcc thinks we have float128 support, but luajit doesn't support it
			code = code:gsub('[^\n]*_Float128[^\n]*', '')

			return code
		end,
	},

-- requires manual manipulation:

	-- this is here for require() insertion but cannot be used for generation
	-- it must be manually extracted from c/setjmp.lua
	{dontGen=true, inc='<bits/setjmp.h>', out='Linux/c/bits/setjmp.lua'},

	{dontGen=true, inc='<bits/dirent.h>', out='Linux/c/bits/dirent.lua', final=function(code)
		code = commentOutLine(code, 'enum { __undef_ARG_MAX = 1 };')
		return code
	end},

	-- this file doesn't exist. stdio.h and stdarg.h both define va_list, so I put it here
	-- but i guess it doesn't even have to be here.
	--{dontGen=true, inc='<va_list.h>', out='Linux/c/va_list.lua'},

	-- same with just.  just a placeholder:
	--{dontGen=true, inc='<__FD_SETSIZE.h>', out='Linux/c/__FD_SETSIZE.lua'},


	-- depends on limits.h bits/posix1_lim.h
	-- because lua.ext uses some ffi stuff, it says "attempt to redefine 'dirent' at line 2"  for my load(path(...):read()) but not for require'results....'
	{
		inc = '<dirent.h>',
		out = 'Linux/c/dirent.lua',
		final = function(code)
			code = fixEnumsAndDefineMacrosInterleaved(code)
			code = remove_need_macro(code)
			return code
		end,
	},

	-- depends: sched.h time.h
	{inc='<pthread.h>', out='Linux/c/pthread.lua', final=function(code)
			code = fixEnumsAndDefineMacrosInterleaved(code)
			return code
	end},

	{inc='<sys/param.h>', out='Linux/c/sys/param.lua', final=function(code)
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
		code = remove_need_macro(code)
		return code
	end},

	{inc='<sys/time.h>', out='Linux/c/sys/time.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'suseconds_t')
		code = fixEnumsAndDefineMacrosInterleaved(code)
		return code
	end},


	-- TODO
	-- uses a vararg macro which I don't support yet
--	{inc='<sys/sysinfo.h>', out='Linux/c/sys/sysinfo.lua'},

	-- depends on bits/libc-header-start
	-- '<identifier>' expected near '_Complex' at line 2
	-- has to do with enum/define'ing the builtin word _Complex
	{inc='<complex.h>', out='Linux/c/complex.lua', final=function(code)
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

}:mapi(function(inc)
	inc.os = 'Linux'	-- meh?
	return inc
end))

-- ]====] End Linux-specific:
includeList:append(table{

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
			code = remove_need_macro(code)

			-- add some macros onto the end manually
			code = code .. [[

local zlib = require 'ffi.load' 'z'
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
return require 'ffi.load' 'ffi'
]]
		return code
	end},

	-- depends: stdbool.h
	-- apt install libgif-dev
	{inc='<gif_lib.h>', out='gif.lua', final=function(code)
		code = [[
]] .. code .. [[
return require 'ffi.load' 'gif'
]]
		return code
	end},

	{inc='<fitsio.h>', out='fitsio.lua', final=function(code)
		code = removeWarnings(code)	-- LLONG_MIN
		-- OFF_T is define'd to off_t soo ...
		code = code:gsub('enum { OFF_T = 0 };\n', '')
		code = code:gsub('OFF_T', 'off_t')
		code = remove_need_macro(code)
		code = code .. [[
return require 'ffi.load' 'cfitsio'
]]
		return code
	end},

	-- apt install libnetcdf-dev
	{inc='<netcdf.h>', out='netcdf.lua', flags=string.trim(io.readproc'pkg-config --cflags netcdf'), final=function(code)
		code = code .. [[
return require 'ffi.load' 'netcdf'
]]
		return code
	end},

	-- apt install libhdf5-dev
	-- depends: inttypes.h
	{
		inc = '<hdf5.h>',
		out = 'hdf5.lua',
		flags = string.trim(io.readproc'pkg-config --cflags hdf5'),
		final = function(code)
			-- old header comment:
				-- for gcc / ubuntu looks like off_t is defined in either unistd.h or stdio.h, and either are set via testing/setting __off_t_defined
				-- in other words, the defs in here are getting more and more conditional ...
				-- pretty soon a full set of headers + full preprocessor might be necessary
				-- TODO regen this on Windows and compare?
			code = removeWarnings(code)	-- LLONG_MIN
			code = remove_need_macro(code)
			code = code .. [[
return require 'ffi.load' 'hdf5'	-- pkg-config --libs hdf5
]]
			return code
		end,
		-- ffi.load override information
		-- TODO somehow insert this into ffi/load.lua without destroying the file
		-- don't modify require 'ffi.load' within 'ffi.hdf5', since the whole point of fif.load is for the user to provide overrides to the lib loc that the header needs.
		ffiload = {
			hdf5 = {Linux = '/usr/lib/x86_64-linux-gnu/hdf5/serial/libhdf5.so'},
		},
	},

	-- depends on: stdio.h stdint.h stdarg.h stdbool.h
	{
		-- cimgui has these 3 files together:
		-- OpenGL i had to separate them
		-- and OpenGL i put them in OS-specific place
		inc = '"cimgui.h"',
		moreincs = {
			'"imgui_impl_sdl2.h"',
			'"imgui_impl_opengl3.h"',
		},
		silentincs = {'"imgui.h"'},	-- full of C++ so don't include it
		flags = '-I/usr/local/include/imgui-1.89.7dock -DCIMGUI_DEFINE_ENUMS_AND_STRUCTS',
		out = 'cimgui.lua',
		final = function(code)
			-- this is already in SDL
			code = code:gsub(
				string.patescape'struct SDL_Window;'..'\n'
				..string.patescape'struct SDL_Renderer;'..'\n'
				..string.patescape'typedef union SDL_Event SDL_Event;',

				-- simultaneously insert require to ffi/sdl.lua
				"]] require 'ffi.req' 'sdl' ffi.cdef[["
			)
			code = remove_need_macro(code)

			-- looks like in the backend file there's one default parameter value ...
			code = code:gsub('glsl_version = nullptr', 'glsl_version')

			code = code .. [[
return require 'ffi.load' 'cimgui_sdl'
]]
			return code
		end,
	},

	{
		inc = '<CL/cl.h>',
		moreincs = {'<CL/cl_gl.h>'},
		out = 'OpenCL.lua',
		final = function(code)
			code = commentOutLine(code, 'warning: Need to implement some method to align data here')

			-- ok because I have more than one inc, the second inc points back to the first, and so we do create a self-reference
			-- so fix it here:
			code = code:gsub(string.patescape"]] require 'ffi.req' 'OpenCL' ffi.cdef[[\n", "")

			code = code .. [[
return require 'ffi.load' 'OpenCL'
]]
			return code
		end,
	},

-- these external files are per-OS
-- maybe eventually all .h's will be?


	-- apt install libtiff-dev
	-- also per-OS
	-- depends: stddef.h stdint.h inttypes.h stdio.h stdarg.h
	{
		inc = '<tiffio.h>',
		out = ffi.os..'/tiff.lua',
		os = ffi.os,
		flags = string.trim(io.readproc'pkg-config --cflags libtiff-4'),
		final = function(code)
			code = remove_need_macro(code)
			return code
		end,
	},

	-- apt install libjpeg-turbo-dev
	-- linux is using 2.1.2 which generates no different than 2.0.3
	--  based on apt package libturbojpeg0-dev
	-- windows is using 2.0.4 just because 2.0.3 and cmake is breaking for msvc
	{
		inc = '<jpeglib.h>',
		out = ffi.os..'/jpeg.lua',
		os = ffi.os,
		final = function(code)
			code = [[
require 'ffi.req' 'c.stdio'	-- for FILE, even though jpeglib.h itself never includes <stdio.h> ... hmm ...
]] .. code
			return code
		end,
		ffiload = {
			jpeg = {
				-- For Windows msvc turbojpeg 2.0.3 cmake wouldn't build, so i used 2.0.4 instead
				-- I wonder if this is the reason for the few subtle differences
				-- TODO rebuild linux with 2.0.4 and see if they go away?
				Windows = 'jpeg8',
				-- for Linux, libturbojpeg 2.1.2 (which is not libjpeg-turbo *smh* who named this)
				-- the header generated matches libturbojpeg 2.0.3 for Ubuntu ... except the version macros
			},
		},
	},

	-- used by GL, GLES1, GLES2 ...
	{
		inc = '<KHR/khrplatform.h>',
		out = 'KHR/khrplatform.lua',
	},

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
		out = ffi.os..'/OpenGL.lua',
		os = ffi.os,
		final = function(code)
			code = code .. [[
return require 'ffi.load' 'GL'
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
			code = remove_need_macro(code)
			code = [[
]] .. code .. [[
return require 'ffi.load' 'lua'
]]
			return code
		end,
	},

	-- depends on complex.h
	{inc='<cblas.h>', out='cblas.lua', final=function(code)
		code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		code = [[
]] .. code .. [[
return require 'ffi.load' 'openblas'
]]
		return code
	end},

	{inc='<lapack.h>', out='lapack.lua', final=function(code)
		-- needs lapack_int replaced with int, except the enum def line
		-- the def is conditional, but i think this is the right eval ...
		code = code:gsub('enum { lapack_int = 0 };', 'typedef int32_t lapack_int;')
--[[
#if defined(LAPACK_ILP64)
#define lapack_int        int64_t
#else
#define lapack_int        int32_t
#endif
--]]

		-- preproc on this generate a *LOT* of `enum { LAPACK_lsame_base = 0 };`
		-- they are generated from macro calls to LAPACK_GLOBAL
		-- which is defined as
		-- #define LAPACK_GLOBAL(lcname,UCNAME)  lcname##_
		-- ... soo ... I need to not gen enums for macros that do string manipulation or whatever
		code = code:gsub('enum { LAPACK_[_%w]+ = 0 };', '')
		code = code:gsub('\n\n', '\n')

		code = code .. [[
return require 'ffi.load' 'lapack'
]]
		return code
	end},

	{inc='<lapacke.h>', out='lapacke.lua', final=function(code)
		code = code .. [[
return require 'ffi.load' 'lapacke'
]]
		return code
	end},

	-- libzip-dev
	-- TODO #define ZIP_OPSYS_* is hex values, should be enums, but they are being commented out ...
	{inc='<zip.h>', out='zip.lua', final=function(code)
		code = code .. [[
return require 'ffi.load' 'zip'
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
return require 'ffi.load' 'png'
]]
		return code
	end},

	-- TODO STILL
	-- looks like atm i'm using a hand-rolled sdl anyways
	{
		inc = '<SDL2/SDL.h>',
		out = 'sdl.lua',
		flags = string.trim(io.readproc'pkg-config --cflags sdl2'),
		silentincs = {
			'<immintrin.h>',
		},
		final = function(code)
			code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
			-- warning: redefining __MATH_DECLARING_DOUBLE from 1 to 0 (originally 0)
			-- warning: redefining __MATH_DECLARING_FLOATN from 0 to 1 (originally 1)
			code = removeWarnings(code)

			code = code:gsub('enum { _begin_code_h = 1 };', '')

			code = code .. [[
return require 'ffi.load' 'SDL2'
]]
			return code
		end,
	},

	{
		inc = '<ogg/ogg.h>',
		-- build this separately for each OS.
		-- generate the os splitter file
		out = ffi.os..'/ogg.lua',
		os = ffi.os,
	},

	{
		inc = '<vorbis/codec.h>',
		out = 'vorbis/codec.lua',
	},
	{
		inc = '<vorbis/vorbisfile.h>',
		out = 'vorbis/vorbisfile.lua',
		flags = '-I/usr/include/vorbis',
		final = function(code)
			-- the result contains some inline static functions and some static struct initializers which ffi cdef can't handle
			-- ... I need to comment it out *HERE*.
			code = code:gsub('static int _ov_header_fseek_wrap%b()%b{}', '')
			code = code:gsub('static ov_callbacks OV_CALLBACKS_[_%w]+ = %b{};', '')

			code = code .. [[
local lib = require 'ffi.load' 'vorbisfile'

-- don't use stdio, use ffi.C
-- stdio risks browser shimming open and returning a Lua function
-- but what that means is, for browser to work with vorbisfile,
-- browser will have to shim each of he OV_CALLBACKs
-- ... or browser should/will have to return ffi closures of ffi.open
-- ... then we can use stdio here
local stdio = require 'ffi.req' 'c.stdio'	-- fopen, fseek, fclose, ftell

-- i'd free the closure but meh
-- who puts a function as a static in a header anyways?
local _ov_header_fseek_wrap = ffi.cast('int (*)(void *, ogg_int64_t, int)', function(f,off,whence)
	if f == nil then return -1 end
	return stdio.fseek(f,off,whence)
end)

local OV_CALLBACKS_DEFAULT = ffi.new'ov_callbacks'
OV_CALLBACKS_DEFAULT.read_func = stdio.fread
OV_CALLBACKS_DEFAULT.seek_func = _ov_header_fseek_wrap
OV_CALLBACKS_DEFAULT.close_func = stdio.fclose
OV_CALLBACKS_DEFAULT.tell_func = stdio.ftell

local OV_CALLBACKS_NOCLOSE = ffi.new'ov_callbacks'
OV_CALLBACKS_NOCLOSE.read_func = stdio.fread
OV_CALLBACKS_NOCLOSE.seek_func = _ov_header_fseek_wrap
OV_CALLBACKS_NOCLOSE.close_func = nil
OV_CALLBACKS_NOCLOSE.tell_func = stdio.ftell

local OV_CALLBACKS_STREAMONLY = ffi.new'ov_callbacks'
OV_CALLBACKS_STREAMONLY.read_func = stdio.fread
OV_CALLBACKS_STREAMONLY.seek_func = nil
OV_CALLBACKS_STREAMONLY.close_func = stdio.fclose
OV_CALLBACKS_STREAMONLY.tell_func = nil

local OV_CALLBACKS_STREAMONLY_NOCLOSE = ffi.new'ov_callbacks'
OV_CALLBACKS_STREAMONLY_NOCLOSE.read_func = stdio.fread
OV_CALLBACKS_STREAMONLY_NOCLOSE.seek_func = nil
OV_CALLBACKS_STREAMONLY_NOCLOSE.close_func = nil
OV_CALLBACKS_STREAMONLY_NOCLOSE.tell_func = nil

return setmetatable({
	OV_CALLBACKS_DEFAULT = OV_CALLBACKS_DEFAULT,
	OV_CALLBACKS_NOCLOSE = OV_CALLBACKS_NOCLOSE,
	OV_CALLBACKS_STREAMONLY = OV_CALLBACKS_STREAMONLY,
	OV_CALLBACKS_STREAMONLY_NOCLOSE = OV_CALLBACKS_STREAMONLY_NOCLOSE,
}, {
	__index = lib,
})
]]
			return code
		end,
	},

	{
		inc = '<EGL/egl.h>',
		out = 'EGL.lua',
		final = function(code)
			return code .. [[
return setmetatable({
	EGL_DONT_CARE = ffi.cast('EGLint', -1),
	EGL_NO_CONTEXT = ffi.cast('EGLDisplay',0),
	EGL_NO_DISPLAY = ffi.cast('EGLDisplay',0),
	EGL_NO_SURFACE = ffi.cast('EGLSurface',0),
	EGL_UNKNOWN = ffi.cast('EGLint',-1),
	EGL_DEFAULT_DISPLAY = ffi.cast('EGLNativeDisplayType',0),
	EGL_NO_SYNC = ffi.cast('EGLSync',0),
	EGL_NO_IMAGE = ffi.cast('EGLImage',0),
}, {
	__index = require 'ffi.load' 'EGL',
})
]]
		end,
	},
	{
		inc = '<GLES/gl.h>',
		out = 'OpenGLES1.lua',
		final = function(code)
			return code .. [[
return require 'ffi.load' 'GLESv1_CM'
]]
		end,
	},
	{
		inc = '<GLES2/gl2.h>',
		out = 'OpenGLES2.lua',
		final = function(code)
			return code .. [[
return require 'ffi.load' 'GLESv2'
]]
		end,
	},
	{
		inc = '<GLES3/gl3.h>',
		out = 'OpenGLES3.lua',
		final = function(code)
			-- why don't I have a GLES3 library when I have GLES3 headers?
			return code .. [[
return require 'ffi.load' 'GLESv2'
]]
		end,
	},
	{
		inc = '<AL/al.h>',
		moreincs = {
			'<AL/alc.h>',
		},
		out = 'OpenAL.lua',
		final = function(code)
			return code .. [[
return require 'ffi.load' 'openal'
]]
		end,
		ffiload = {
			openal = {Windows = 'OpenAL32'},
		},
	},
})

-- now detect any duplicate #include paths and make sure they are going to distinct os-specific destination file names
-- and in those cases, add in a splitting file that redirects to the specific OS
local detectDups = {}
for _,inc in ipairs(includeList) do
	detectDups[inc.inc] = detectDups[inc.inc] or {}
	local det = detectDups[inc.inc][inc.os or 'all']
	if det then
		print("got two entries that have matching include name, and at least one is not os-specific: "..tolua{
			det,
			inc,
		})
	end
	detectDups[inc.inc][inc.os or 'all'] = inc
end
for incname, det in pairs(detectDups) do
	if type(det) == 'table' then
		local keys = table.keys(det)
		-- if we had more than 1 key
		if #keys > 1
		then
			local base
			for os,inc in pairs(det) do
				assert(inc.os, "have a split file and one entry doesn't have an os... "..tolua(inc))
				local incbase = inc.out:match('^'..inc.os..'/(.*)$')
				if not incbase then
					error("expected os "..tolua(inc.os).." prefix, bad formatted out for "..tolua(inc))
				end
				if base == nil then
					base = incbase
				else
					assert(incbase == base, "for split file, assumed output is [os]/[path] ,but didn't get it for "..tolua(inc))
				end
			end
--[=[ add in the split file
			includeList:insert{
				inc = incname,
				out = base,
				-- TODO this assumes it is Windows vs all, and 'all' is stored in Linux ...
				-- TODO autogen by keys.  non-all <-> if os == $key, all <-> else, no 'all' present <-> else error "idk your os" unless you wanna have Linux the default
				forcecode = template([[
local ffi = require 'ffi'
if ffi.os == 'Windows' then
	return require 'ffi.Windows.<?=req?>'
else
	return require 'ffi.Linux.<?=req?>'
end
]], 			{
					req = (assert(base:match'(.*)%.lua', 'expcted inc.out to be ext .lua')
						:gsub('/', '.')),
				})
			}
--]=]
		end
	end
end


return includeList

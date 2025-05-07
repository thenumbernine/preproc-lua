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
local path = require 'ext.path'
local assert = require 'ext.assert'
local string = require 'ext.string'
local table = require 'ext.table'
local io = require 'ext.io'
local tolua = require 'ext.tolua'

-- needs to match generate.lua or make.lua or wherever i'm setting it.
local enumGenUnderscoreMacros = true

-- for all these .final() functions,
-- wrap them in a function that detects if the modification took place, and writes a warning to stderr if it didn't.
-- that way as versions increment I can know which filters are no longer needed.
local function safegsub(s, from, to, ...)
	local n
	s, n = string.gsub(s, from, to, ...)
	if n == 0 then
		-- TODO use the calling function from stack trace ... but will it always exist?
		io.stderr:write('UNNECESSARY: ', tostring(from), '\n')
	end
	return s
end

local function remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
	return safegsub(
		code,
		'enum { __GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION = 1 };\n',
		'')
end

-- TODO maybe ffi.Linux.c.bits.types instead
-- pid_t and pid_t_defined are manually inserted into lots of dif files
-- i've separated it into its own file myself, so it has to be manually replaced
-- same is true for a few other types
local function replace_bits_types_builtin(code, ctype)
	-- if we're excluing underscore macros this then the enum line won't be there.
	-- if we're including underscore macros then the enum will be multiply defined and need to b removed
	-- one way to unify these is just remove the enum regardless (in the filter() function) and then gsub the typedef with the require
	if enumGenUnderscoreMacros then
		return safegsub(
			code,
			string.patescape(
				[[typedef __]]..ctype..[[ ]]..ctype..[[;]]
			),
			[=[]] require 'ffi.req' 'c.bits.types.]=]..ctype..[=[' ffi.cdef[[]=]
		)
	else
		return safegsub(
			code,
			string.patescape([[
typedef __]]..ctype..[[ ]]..ctype..[[;
enum { __]]..ctype..[[_defined = 1 };]]
			),
			[=[]] require 'ffi.req' 'c.bits.types.]=]..ctype..[=[' ffi.cdef[[]=]
		)
	end
end

local function removeEnum(code, enumstr)
	return safegsub(
		code,
		'enum { '..enumstr..' };\n',
		''
	)
end

local function remove_need_macro(code)
	return safegsub(
		code,
		'enum { __need_[_%w]* = 1 };\n',
		''
	)
end

-- _VA_LIST_DEFINED and va_list don't appear next to each other like the typical bits_types_builtin do
local function remove_VA_LIST_DEFINED(code)
	return safegsub(
		code,
		'enum { _VA_LIST_DEFINED = 1 };\n',
		'')
end

local function replace_va_list_require(code)
	return safegsub(
		code,
		'typedef __gnuc_va_list va_list;',
		[=[]] require 'ffi.req' 'c.va_list' ffi.cdef[[]=]
	)
end

-- unistd.h and stdio.h both define SEEK_*, so ...
local function replace_SEEK(code)
	return safegsub(
		code,
		[[
enum { SEEK_SET = 0 };
enum { SEEK_CUR = 1 };
enum { SEEK_END = 2 };
]],
		"]] require 'ffi.req' 'c.bits.types.SEEK' ffi.cdef[[\n"
	)
end

-- TODO keeping warnings as comments seems nice
--  but they insert at the first line
--  which runs the risk of bumping the first line skip of BEGIN ...
--  which could replcae the whole file with a require()
local function removeWarnings(code)
	return safegsub(
		code,
		'warning:[^\n]*\n',
		''
	)
end

local function commentOutLine(code, line)
	return safegsub(
		code,
		string.patescape(line),
		'/* manually commented out: '..line..' */'
	)
end

-- ok with {.-} it fails on funcntions that have {}'s in their body, like wmemset
-- so lets try %b{}
-- TODO name might have a * before it instead of a space...
local function removeStaticFunction(code, name)
	return safegsub(
		code,
		'static%s[^(]-%s'..name..'%s*%(.-%)%s*%b{}',
		''
	)
end

local function removeStaticInlineFunction(code, name)
	return safegsub(
		code,
		'static%sinline%s[^(]-%s'..name..'%s*%(.-%)%s*%b{}',
		''
	)
end

local function remove__inlineFunction(code, name)
	return safegsub(
		code,
		'__inline%s[^(]-%s'..name..'%s*%(.-%)%s*%b{}',
		''
	)
end

local function removeDeclSpecNoInlineFunction(code, name)
	return safegsub(
		code,
		'__declspec%(noinline%)%s*__inline%s[^(]-%s'..name..'%s*%(.-%)%s*%b{}',
		''
	)
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

-- pkgconfig doesn't work on windows so rather than try and fail a lot ...
local function pkgconfigFlags(name)
	if ffi.os == 'Windows' then return nil end
	return string.trim(io.readproc('pkg-config --cflags '..assert(name)))
end

-- some _asm directives have #sym instead of "sym" and also need their quotes merged ...
local function fixasm(code)
	return (code:gsub('__asm(%b())', function(s)
		s = assert((s:match'^%((.*)%)$'))
		-- at this point osx is nice enough to space-separate tokens
		-- however I should account for non-space-separated.  TODO.
		s = string.trim(s)
		s = string.split(s, '%s+'):mapi(function(w)
			local inside = w:match('^"(.*)"$')
			if inside then return inside end	-- TODO string escape chars?
			if w:sub(1,1) == '#' then return w:sub(2) end
			error("idk "..tostring(w))
		end):concat()

		-- here's another weird thing
		s = assert(s:match'^_(.*)$')

		return '__asm("' .. s .. '")'
	end))
end

--[[
args:
	code = code,
--]]
local function makeLibWrapper(args)
	local code = assert(args.code)

	local lines = string.split(code, '\n')
	assert.eq(lines:remove(1), "local ffi = require 'ffi'")
	assert.eq(lines:remove(1), 'ffi.cdef[[')
	assert.eq(lines:remove(), '')
	assert.eq(lines:remove(), ']]')

	-- undo the #include <-> require()'s, since they will go at the top
	-- but there's none in libjpeg...
	local requires = table()
	local reqpat = '^'
		..string.patescape"]] "
		.."(require 'ffi.req' '.*')"
		..string.patescape"' ffi.cdef[["
		..'$'
	for i=#lines,1,-1 do
		local line = lines[i]
		local req = line:match(reqpat)
		if req then
			lines:remove(i)
			requires:insert(1, req)
		end
	end

	code = lines:concat'\n'

	local CHeaderParser = require 'c-h-parser'
	local header = CHeaderParser()
-- debugging
path'~before-c-h-parser.h':write(code)
	assert(header(code))

	if args.insertRequires then
		requires = table(args.insertRequires):append(requires)
	end

	code = table{
		"local ffi = require 'ffi'",
		'\n-- typedefs\n',
		requires:concat'\n',
		'ffi.cdef[[',
		header.declTypes:mapi(function(node)
			return node:toC()..';'
		end):concat'\n',
		']]',
		[[

local wrapper
wrapper = require 'ffi.libwrapper'{]],
	}:append(
		args.libname and {[[	lib = require 'ffi.load' ']]..args.libname..[[',]]} or nil
	):append{
[[
	defs = {
		-- enums
]],
		header.anonEnumValues:mapi(function(node)
			return '\t\t'..node:toC()..','
		end):concat'\n',

		'\n\t\t-- functions\n',

		header.symbolsInOrder:mapi(function(node)
			-- assert it is a decl
			assert.is(node, header.ast._decl)
			assert.len(node.subdecls, 1)
			-- get name-most ...
			local name = node.subdecls[1]
			while type(name) ~= 'string' do
				name = name[1]
			end
			-- remove extern qualifier if it's there
			node.stmtQuals.extern = nil
			return '\t\t'
				..name..' = [['
				..node:toC()
				..';]],'
		end):concat'\n',
	}:append(
		libDefs and {'\t\t'..libDefs:gsub('\n', '\n\t\t')} or nil
	):append{
		[[
	},
}]],
	}:append(
		args.footerCode and {args.footerCode} or nil
	):append{
		'return wrapper',
	}:concat'\n'..'\n'

	return code
end

local includeList = table()

-- files found in multiple OS's will go in [os]/[path]
-- and then in just [path] will be a file that determines the file based on os (and arch?)

-- [====[ Begin Windows-specific:
-- TODO this is most likely going to be come Windows/x64/ files in the future
includeList:append(table{
-- Windows-only:
	{inc='<vcruntime_string.h>', out='Windows/c/vcruntime_string.lua'},

	{inc='<corecrt.h>', out='Windows/c/corecrt.lua'},

	{inc='<corecrt_share.h>', out='Windows/c/corecrt_share.lua'},

	{inc='<corecrt_wdirect.h>', out='Windows/c/corecrt_wdirect.lua'},

	{
		inc = '<corecrt_stdio_config.h>',
		out = 'Windows/c/corecrt_stdio_config.lua',
		final = function(code)
			for _,f in ipairs{
				'__local_stdio_printf_options',
				'__local_stdio_scanf_options',
			} do
				code = remove__inlineFunction(code, f)
			end
			return code
		end,
	},

	-- depends: corecrt_stdio_config.h
	{inc='<corecrt_wstdio.h>', out='Windows/c/corecrt_wstdio.lua'},

	-- depends: corecrt_share.h
	{inc = '<corecrt_wio.h>', out = 'Windows/c/corecrt_wio.lua'},

	-- depends: vcruntime_string.h
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
			for _,f in ipairs{
				'ctime',
				'difftime',
				'gmtime',
				'localtime',
				'_mkgmtime',
				'mktime',
				'time',
				'timespec_get',
			} do
				code = removeStaticFunction(code, f)
			end
			-- add these static inline wrappers as lua wrappers
			-- TODO pick between 32 and 64 based on arch
			code = code .. [[
local lib = ffi.C
if ffi.arch == 'x86' then
	return setmetatable({
		_wctime = lib._wctime32,		-- in corecrt_wtime.h
		_wctime_s = lib._wctime32_s,		-- in corecrt_wtime.h
		ctime = _ctime32,
		difftime = _difftime32,
		gmtime = _gmtime32,
		localtime = _localtime32,
		_mkgmtime = _mkgmtime32,
		mktime = _mktime32,
		time = _time32,
		timespec_get = _timespec32_get,
	}, {
		__index = lib,
	})
elseif ffi.arch == 'x64' then
	return setmetatable({
		_wctime = lib._wctime64,		-- in corecrt_wtime.h
		_wctime_s = lib._wctime64_s,		-- in corecrt_wtime.h
		ctime = _ctime64,
		difftime = _difftime64,
		gmtime = _gmtime64,
		localtime = _localtime64,
		_mkgmtime = _mkgmtime64,
		mktime = _mktime64,
		time = _time64,
		timespec_get = _timespec64_get,
	}, {
		__index = lib,
	})
end
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

	-- depends on: errno.h corecrt_wstring.h vcruntime_string.h
	{inc = '<string.h>', out = 'Windows/c/string.lua'},

	-- depends on: corecrt_wio.h, corecrt_share.h
	-- really it just includes corecrt_io.h
	{
		inc = '<io.h>',
		out = 'Windows/c/io.lua',
		final = function(code)
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

	-- depends on: errno.h corecrt_wio.h corecrt_wstring.h corecrt_wdirect.h corecrt_stdio_config.h corecrt_wtime.h vcruntime_string.h
	{
		inc = '<wchar.h>',
		out = 'Windows/c/wchar.lua',
		final = function(code)
			for _,f in ipairs{
				'fwide',
				'mbsinit',
				'wmemchr',
				'wmemcmp',
				'wmemcpy',
				'wmemmove',
				'wmemset',
			} do
				code = remove__inlineFunction(code, f)
			end

			-- corecrt_wio.h #define's types that I need, so typedef them here instead
			-- TODO pick according to the current macros
			-- but make.lua and generate.lua run in  separate processes, so ....
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

	-- [[ TODO verify these work
	{inc = '<fcntl.h>', out = 'Windows/c/fcntl.lua'},
	{inc = '<sys/mman.h>', out = 'Windows/c/sys/mman.lua'},
	--]]

	-- depends: corecrt_stdio_config.h
	{
		inc = '<stdio.h>',
		out = 'Windows/c/stdio.lua',
		final = function(code)
			-- return ffi.C so it has the same return behavior as Linux/c/stdio
			code = code .. [[
local lib = ffi.C
return setmetatable({
	fileno = lib._fileno,
}, {
	__index = ffi.C,
})
]]
			return code
		end,
	},

	-- depends: sys/types.h
	{
		inc = '<sys/stat.h>',
		out = 'Windows/c/sys/stat.lua',
		final = function(code)
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
	-- because they use suffixes i8, i16, i32, i64, ui8, ui16, ui32, ui64
	-- (hmm similar but different set of macros are in limits.h)
	-- but the types it added ... int8_t ... etc ... are alrady buitin to luajit?
	-- no they are microsoft-specific:
	-- https://stackoverflow.com/questions/33659846/microsoft-integer-literal-extensions-where-documented
	-- so this means replace them wherever possible.
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

	-- used by GL, GLES1, GLES2 ...
	{
		inc = '<KHR/khrplatform.h>',
		out = 'Windows/KHR/khrplatform.lua',
	},

	-- used by SDL
	{
		inc = '<process.h>',
		out = 'Windows/c/process.lua',
	},

}:mapi(function(inc)
	inc.os = 'Windows'
	return inc
end))
--]====] End Windows-specifc:

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
			--code = safegsub(code, '(128[_%w]*) = 1', '%1 = 0')
			return code
		end,
	},

	{inc='<bits/types.h>', out='Linux/c/bits/types.lua'},

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
	{
		inc = '<sys/termios.h>',
		out = 'Linux/c/sys/termios.lua',
		final = function(code)
			code = replace_bits_types_builtin(code, 'pid_t')
			code = removeEnum(code, 'USE_CLANG_%w* = 0')
			return code
		end,
	},

	-- used by c/pthread, c/sys/types, c/signal
	{
		inc = '<bits/pthreadtypes.h>',
		silentincs = {
			'<features.h>',
		},
		out = 'Linux/c/bits/pthreadtypes.lua',
	},

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
		return code
	end},

	{inc='<linux/limits.h>', out='Linux/c/linux/limits.lua'},

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
	{
		dontGen = true,
		inc = '<bits/libc-header-start.h>',
		out = 'Linux/c/bits/libc-header-start.lua',
		final = function(code)
			return remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
		end,
	},

	-- depends: features.h stddef.h bits/libc-header-start.h
	{inc='<string.h>', out='Linux/c/string.lua'},

	-- depends: features.h stddef.h bits/types.h and too many really
	-- this and any other file that requires stddef might have these lines which will have to be removed:
	{
		inc = '<time.h>',
		out = 'Linux/c/time.lua',
		final = function(code)
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

	-- used by <sys/stat.h>, <fcntl.h>
	{
		dontGen = true,	-- I hate the "don't include this directly" error messages ...
		inc = '<bits/stat.h>',
		out = 'Linux/c/bits/stat.lua',
	},

	-- depends: bits/types.h etc
	{
		inc = '<sys/stat.h>',
		out = 'Linux/c/sys/stat.lua',
		final = function(code)
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
local statlib = setmetatable({
	struct_stat = 'struct stat',
}, {
	__index = lib,
})
-- allow nils instead of errors if we access fields not present (for the sake of lfs_ffi)
ffi.metatype(statlib.struct_stat, {
	__index = function(t,k)
		return nil
	end,
})
return statlib
]]
			return code
		end,
	},

	-- depends: bits/types.h
	{
		inc = '<stdint.h>',
		out = 'Linux/c/stdint.lua',
		final = function(code)
			--code = replace_bits_types_builtin(code, 'intptr_t')
			-- not the same def ...
			code = safegsub(
				code,
				[[
typedef long int intptr_t;
]],
				[=[]] require 'ffi.req' 'c.bits.types.intptr_t' ffi.cdef[[]=]
			)


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
			code = safegsub(
				code,
				string.patescape[[
enum { WCHAR_MIN = -2147483648 };
enum { WCHAR_MAX = 2147483647 };
]],
				[=[]] require 'ffi.req' 'c.wchar' ffi.cdef[[]=]
			)

			return code
		end,
	},

	-- depends: features.h sys/types.h
	{inc = '<stdlib.h>', out = 'Linux/c/stdlib.lua'},

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
	{inc = '<wchar.h>', out = 'Linux/c/wchar.lua'},

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
	{inc='<limits.h>', out='Linux/c/limits.lua'},

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

			-- both unistd.h and stdio.h have SEEK_* defined, so ...
			-- you'll have to manually create this file
			code = replace_SEEK(code)

			--[=[
			code = safegsub(
				code,
				-- TODO i'm sure this dir will change in the future ...
				string.patescape('/* ++ BEGIN /usr/include/x86_64-linux-gnu/bits/confname.h */')
				..'.*'
				..string.patescape('/* ++ END   /usr/include/x86_64-linux-gnu/bits/confname.h */'),
				[[

/* TODO here I skipped conframe because it was too many mixed enums and ddefines => enums  .... but do I still need to, because it seems to be sorted out. */
]]
			)
			--]=]
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
		return code
	end},

	-- depends on too much
	{inc='<stdarg.h>', out='Linux/c/stdarg.lua', final=function(code)
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

	-- [[ TODO verify these work
	{inc = '<fcntl.h>', out = 'Linux/c/fcntl.lua'},
	{inc = '<sys/mman.h>', out = 'Linux/c/sys/mman.lua'},
	--]]

	-- depends on too much
	-- moving to Linux-only block since now it is ...
	-- it used to be just after stdarg.h ...
	-- maybe I have to move everything up to that file into the Linux-only block too ...
	{
		inc = '<stdio.h>',
		out = 'Linux/c/stdio.lua',
		final = function(code)
			code = replace_bits_types_builtin(code, 'off_t')
			code = replace_bits_types_builtin(code, 'ssize_t')
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
			-- [[ enums and #defines intermixed ... smh
			code = safegsub(code, ' ([_%a][_%w]*) = enum { ([_%a][_%w]*) = %d+ };', function(a,b)
				if a == b then return ' '..a..' = ' end
				return '%0'
			end)
			--]]

			-- gcc thinks we have float128 support, but luajit doesn't support it
			code = safegsub(code, '[^\n]*_Float128[^\n]*', '')

			return code
		end,
	},

-- requires manual manipulation:

	{
		dontGen = true,
		inc = '<bits/dirent.h>',
		out = 'Linux/c/bits/dirent.lua',
		final = function(code)
			code = commentOutLine(code, 'enum { __undef_ARG_MAX = 1 };')
			return code
		end,
	},

	-- this is here for require() insertion but cannot be used for generation
	-- it must be manually extracted from c/setjmp.lua
	{
		dontGen = true,
		inc = '<bits/setjmp.h>',
		out = 'Linux/c/bits/setjmp.lua',
	},

	-- this file doesn't exist. stdio.h and stdarg.h both define va_list, so I put it here
	-- but i guess it doesn't even have to be here.
	--{dontGen = true, inc='<va_list.h>', out='Linux/c/va_list.lua'},

	-- same with just.  just a placeholder:
	--{dontGen = true, inc='<__FD_SETSIZE.h>', out='Linux/c/__FD_SETSIZE.lua'},


	-- depends on limits.h bits/posix1_lim.h
	-- because lua.ext uses some ffi stuff, it says "attempt to redefine 'dirent' at line 2"  for my load(path(...):read()) but not for require'results....'
	{
		inc = '<dirent.h>',
		out = 'Linux/c/dirent.lua',
		final = function(code)
			code = fixEnumsAndDefineMacrosInterleaved(code)
			return code
		end,
	},

	-- depends: sched.h time.h
	{inc='<pthread.h>', out='Linux/c/pthread.lua', final=function(code)
			code = fixEnumsAndDefineMacrosInterleaved(code)
			return code
	end},

	{
		inc = '<signal.h>',
		out = 'Linux/c/signal.lua',
		final = function(code)
			-- i think all these stem from #define A B when the value is a string and not numeric
			--  but my #define to enum inserter forces something to be produced
			code = commentOutLine(code, 'enum { SIGIO = 0 };')
			code = commentOutLine(code, 'enum { SIGCLD = 0 };')
			code = commentOutLine(code, 'enum { SI_DETHREAD = 0 };')
			code = commentOutLine(code, 'enum { SI_TKILL = 0 };')
			code = commentOutLine(code, 'enum { SI_SIGIO = 0 };')
			code = commentOutLine(code, 'enum { SI_ASYNCIO = 0 };')
			code = commentOutLine(code, 'enum { SI_ASYNCNL = 0 };')
			code = commentOutLine(code, 'enum { SI_MESGQ = 0 };')
			code = commentOutLine(code, 'enum { SI_TIMER = 0 };')
			code = commentOutLine(code, 'enum { SI_QUEUE = 0 };')
			code = commentOutLine(code, 'enum { SI_USER = 0 };')
			code = commentOutLine(code, 'enum { SI_KERNEL = 0 };')
			--code = commentOutLine(code, 'enum { ILL_%w+ = 0 };')
			--code = commentOutLine(code, 'enum { __undef_ARG_MAX = 1 };')

			code = commentOutLine(code, 'enum { ILL_ILLOPC = 0 };')
			code = commentOutLine(code, 'enum { ILL_ILLOPN = 0 };')
			code = commentOutLine(code, 'enum { ILL_ILLADR = 0 };')
			code = commentOutLine(code, 'enum { ILL_ILLTRP = 0 };')
			code = commentOutLine(code, 'enum { ILL_PRVOPC = 0 };')
			code = commentOutLine(code, 'enum { ILL_PRVREG = 0 };')
			code = commentOutLine(code, 'enum { ILL_COPROC = 0 };')
			code = commentOutLine(code, 'enum { ILL_BADSTK = 0 };')
			code = commentOutLine(code, 'enum { ILL_BADIADDR = 0 };')
			code = commentOutLine(code, 'enum { FPE_INTDIV = 0 };')
			code = commentOutLine(code, 'enum { FPE_INTOVF = 0 };')
			code = commentOutLine(code, 'enum { FPE_FLTDIV = 0 };')
			code = commentOutLine(code, 'enum { FPE_FLTOVF = 0 };')
			code = commentOutLine(code, 'enum { FPE_FLTUND = 0 };')
			code = commentOutLine(code, 'enum { FPE_FLTRES = 0 };')
			code = commentOutLine(code, 'enum { FPE_FLTINV = 0 };')
			code = commentOutLine(code, 'enum { FPE_FLTSUB = 0 };')
			code = commentOutLine(code, 'enum { FPE_FLTUNK = 0 };')
			code = commentOutLine(code, 'enum { FPE_CONDTRAP = 0 };')
			code = commentOutLine(code, 'enum { SEGV_MAPERR = 0 };')
			code = commentOutLine(code, 'enum { SEGV_ACCERR = 0 };')
			code = commentOutLine(code, 'enum { SEGV_BNDERR = 0 };')
			code = commentOutLine(code, 'enum { SEGV_PKUERR = 0 };')
			code = commentOutLine(code, 'enum { SEGV_ACCADI = 0 };')
			code = commentOutLine(code, 'enum { SEGV_ADIDERR = 0 };')
			code = commentOutLine(code, 'enum { SEGV_ADIPERR = 0 };')
			code = commentOutLine(code, 'enum { SEGV_MTEAERR = 0 };')
			code = commentOutLine(code, 'enum { SEGV_MTESERR = 0 };')
			code = commentOutLine(code, 'enum { SEGV_CPERR = 0 };')
			code = commentOutLine(code, 'enum { BUS_ADRALN = 0 };')
			code = commentOutLine(code, 'enum { BUS_ADRERR = 0 };')
			code = commentOutLine(code, 'enum { BUS_OBJERR = 0 };')
			code = commentOutLine(code, 'enum { BUS_MCEERR_AR = 0 };')
			code = commentOutLine(code, 'enum { BUS_MCEERR_AO = 0 };')
			code = commentOutLine(code, 'enum { CLD_EXITED = 0 };')
			code = commentOutLine(code, 'enum { CLD_KILLED = 0 };')
			code = commentOutLine(code, 'enum { CLD_DUMPED = 0 };')
			code = commentOutLine(code, 'enum { CLD_TRAPPED = 0 };')
			code = commentOutLine(code, 'enum { CLD_STOPPED = 0 };')
			code = commentOutLine(code, 'enum { CLD_CONTINUED = 0 };')
			code = commentOutLine(code, 'enum { POLL_IN = 0 };')
			code = commentOutLine(code, 'enum { POLL_OUT = 0 };')
			code = commentOutLine(code, 'enum { POLL_MSG = 0 };')
			code = commentOutLine(code, 'enum { POLL_ERR = 0 };')
			code = commentOutLine(code, 'enum { POLL_PRI = 0 };')
			code = commentOutLine(code, 'enum { POLL_HUP = 0 };')
			code = commentOutLine(code, 'enum { SIGEV_SIGNAL = 0 };')
			code = commentOutLine(code, 'enum { SIGEV_NONE = 0 };')
			code = commentOutLine(code, 'enum { SIGEV_THREAD = 0 };')
			code = commentOutLine(code, 'enum { SIGEV_THREAD_ID = 0 };')
			code = commentOutLine(code, 'enum { SS_ONSTACK = 0 };')
			code = commentOutLine(code, 'enum { SS_DISABLE = 0 };')

			return code
		end,
	},

	{inc='<sys/param.h>', out='Linux/c/sys/param.lua', final=function(code)
		code = fixEnumsAndDefineMacrosInterleaved(code)
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
	{
		inc = '<complex.h>',
		out = 'Linux/c/complex.lua',
		enumGenUnderscoreMacros = true,
		final = function(code)
			code = remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
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
		end,
	},

	-- apt install libarchive-dev
	{
		inc='<archive.h>',
		moreincs = {
			'<archive_entry.h>',
		},
		out='archive.lua',
		final = function(code)
			code = code .. [[
return require 'ffi.load' 'archive'
]]
			return code
		end,
	},

	-- used by GL, GLES1, GLES2 ...
	{
		inc = '<KHR/khrplatform.h>',
		out = 'Linux/KHR/khrplatform.lua',
	},

	-- included by SDL/SDL_stdinc.h
	-- I'm surprised it's not used more often, has stuff like 'tolower'
	{
		inc = '<ctype.h>',
		out = 'Linux/c/ctype.lua',
	},

}:mapi(function(inc)
	inc.os = 'Linux' -- meh?  just have all these default for -nix systems?
	return inc
end))
-- ]====] End Linux-specific:

-- [====[ Begin OSX-specific:
includeList:append(table{
	{inc='<AvailabilityVersions.h>', out='OSX/c/AvailabilityVersions.lua'},

	-- depends on <AvailabilityVersions.h>
	-- ... SDL.h on OSX separately includes AvailabilityMacros.h without Availability.h
	-- ... and both Availability.h and AvailabilityMacros.h points to AvailabilityVersions.h
	-- (so maybe I could avoid this one file and just let its contents embed into sdl.lua ...)
	{inc='<AvailabilityMacros.h>', out='OSX/c/AvailabilityMacros.lua'},

	-- depends on <AvailabilityMacros.h> and <AvailabilityVersions.h>
	{inc='<Availability.h>', out='OSX/c/Availability.lua'},

	-- used by machine/_types.h and machine/types.h
	-- probably just for i386 processors
	{inc='<i386/_types.h>', out='OSX/c/i386/_types.lua', final=function(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	{inc='<machine/_types.h>', out='OSX/c/machine/_types.lua'},

	{inc='<machine/endian.h>', out='OSX/c/machine/endian.lua', final=function(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	{inc='<sys/_pthread/_pthread_types.h>', out='OSX/c/sys/_pthread/_pthread_types.lua'},

	-- depends on <sys/_pthread/_pthread_types.h> <machine/_types.h>
	{inc='<_types.h>', out='OSX/c/_types.lua', final=function(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	{inc='<sys/_types/_seek_set.h>', out='OSX/c/sys/_types/_seek_set.lua'},

	{inc='<sys/_types/_timespec.h>', out='OSX/c/sys/_types/_timespec.lua'},

	-- depends on <machine/_types.h>
	{inc='<sys/_types/_timeval.h>', out='OSX/c/sys/_types/_timeval.lua', final=function(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	{inc='<sys/_types/_fd_def.h>', out='OSX/c/sys/_types/_fd_def.lua'},

	{inc='<sys/_types/_fd_setsize.h>', out='OSX/c/sys/_types/_fd_setsize.lua'},

	-- used by <sys/stat.h> and <fcntl.h>
	{inc='<sys/_types/_s_ifmt.h>', out='OSX/c/sys/_types/_s_ifmt.lua'},

	-- used by <sys/types.h>, <string.h>, <errno.h>
	{inc='<sys/_types/_errno_t.h>', out='OSX/c/sys/_types/_errno_t.lua'},

	-- depends on <sys/_types/_fd_def.h> <sys/_types/_timeval.h>
	{
		inc = '<sys/_select.h>',
		out = 'OSX/c/sys/_select.lua',
		final = function(code)
			code = fixasm(code)
			return code
		end,
	},

	-- TODO might end up adding sys/_types.h ...
	-- it depends on machine/_types.h

	{inc='<stddef.h>', out='OSX/c/stddef.lua'},

	-- depends on <_types.h> <machine/_types.h>
	{inc='<sys/ioctl.h>', out='OSX/c/sys/ioctl.lua', final=function(code)
		code = fixasm(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	-- depends on <_types.h> <sys/_types/_timespec.h> <sys/_types/_fd_def.h> <machine/_types.h>
	{
		inc='<sys/select.h>',
		out='OSX/c/sys/select.lua',
		final = function(code)
			code = fixasm(code)
			code = removeEnum(code, 'USE_CLANG_%w* = 0')
			return code
		end,
	},

	-- depends on <_types.h> <machine/_types.h>
	{
		inc = '<sys/termios.h>',
		out = 'OSX/c/sys/termios.lua',
		final = function(code)
			code = fixasm(code)
			return code
		end,
	},

	-- depends on <_types.h> <sys/_types/_fd_def.h> <machine/_types.h> <machine/endian.h>
	{inc='<sys/types.h>', out='OSX/c/sys/types.lua', final=function(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	-- depends on <_types.h> <machine/_types.h>
	{
		inc='<string.h>',
		out='OSX/c/string.lua',
		final = function(code)
			code = fixasm(code)
			code = removeEnum(code, 'USE_CLANG_%w* = 0')
			return code
		end,
	},

	-- depends on <_types.h> <sys/_types/_timespec.h> <machine/_types.h>
	{
		inc = '<time.h>',
		out = 'OSX/c/time.lua',
		final = function(code)
			code = fixasm(code)
			code = fixEnumsAndDefineMacrosInterleaved(code)
			code = removeEnum(code, 'USE_CLANG_%w* = 0')
			return code
		end,
	},

	-- depends on <sys/_types/_errno_t.h>
	{
		inc = '<errno.h>',
		out = 'OSX/c/errno.lua',
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

	-- depends on <_types.h>
	{
		inc = '<utime.h>',
		out = 'OSX/c/utime.lua',
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

	-- depends on <_types.h> <sys/_types/_timespec.h> <machine/_types.h>
	{
		inc = '<sys/stat.h>',
		out = 'OSX/c/sys/stat.lua',
		final = function(code)
			code = fixasm(code)
			code = removeEnum(code, 'USE_CLANG_%w* = 0')
			code = code .. [[
local lib = ffi.C
local statlib = setmetatable({
	struct_stat = 'struct stat',
}, {
	__index = lib,
})
-- allow nils instead of errors if we access fields not present (for the sake of lfs_ffi)
ffi.metatype(statlib.struct_stat, {
	__index = function(t,k)
		return nil
	end,
})
return statlib
]]
			return code
		end,
	},

	-- depends on <_types.h> <machine/_types.h>
	{inc='<stdint.h>', out='OSX/c/stdint.lua', final=function(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	-- depends on <machine/_types.h>
	{
		inc = '<sys/signal.h>',
		out='OSX/c/sys/signal.lua',
		final = function(code)
			code = removeEnum(code, 'USE_CLANG_%w* = 0')
			-- [[ #defines within structs ...
			code = code:gsub('enum { FP_PREC_24B = 0 };', '')
			code = code:gsub('enum { FP_PREC_53B = 2 };', '')
			code = code:gsub('enum { FP_PREC_64B = 3 };', '')
			code = code:gsub('enum { FP_RND_NEAR = 0 };', '')
			code = code:gsub('enum { FP_RND_DOWN = 1 };', '')
			code = code:gsub('enum { FP_RND_UP = 2 };', '')
			code = code:gsub('enum { FP_CHOP = 3 };', '')
			--]]
			return code
		end,
	},

	-- depends on <sys/signal.h>, <_types.h> <machine/_types.h> <machine/endian.h>
	{
		inc = '<stdlib.h>',
		out = 'OSX/c/stdlib.lua',
		final = function(code)
			code = fixasm(code)
			code = removeEnum(code, 'USE_CLANG_%w* = 0')

			-- how come __BLOCKS__ is defined ...
			-- TODO disable __BLOCKS__ to omit these:
			code = string.split(code, '\n'):filter(function(l)
				return not l:find'_b%('
			end):concat'\n'

			return code
		end,
	},

	{inc='<sys/syslimits.h>', out='OSX/c/sys/syslimits.lua'},

	-- depends on <sys/syslimits.h>
	{inc='<limits.h>', out='OSX/c/limits.lua', final=function(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	{inc='<setjmp.h>', out='OSX/c/setjmp.lua'},

	-- depends: <features.h> <machine/_types.h> <sys/_types/_seek_set.h>
	{
		inc = '<unistd.h>',
		out = 'OSX/c/unistd.lua',
		final = function(code)
			code = fixasm(code)
			code = removeEnum(code, 'USE_CLANG_%w* = 0')
			-- for interchangeability with Windows ...
			code = code .. [[
return ffi.C
]]
			return code
		end,
	},

	{inc='<sched.h>', out='OSX/c/sched.lua'},

	{inc='<stdarg.h>', out='OSX/c/stdarg.lua'},

	{inc='<stdbool.h>', out='OSX/c/stdbool.lua', final=function(code)
		-- luajit has its own bools already defined
		code = commentOutLine(code, 'enum { bool = 0 };')
		code = commentOutLine(code, 'enum { true = 1 };')
		code = commentOutLine(code, 'enum { false = 0 };')
		return code
	end},

	-- depends on <machine/_types.h>
	{inc='<inttypes.h>', out='OSX/c/inttypes.lua', final=function(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	{inc='<fcntl.h>', out='OSX/c/fcntl.lua', final=function(code)
		code = fixasm(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	{inc='<sys/mman.h>', out='OSX/c/sys/mman.lua', final=function(code)
		code = fixasm(code)
		code = removeEnum(code, 'USE_CLANG_%w* = 0')
		return code
	end},

	-- depends on <machine/_types.h> <sys/_types/_seek_set.h>
	{
		inc = '<stdio.h>',
		out = 'OSX/c/stdio.lua',
		final = function(code)
			code = fixasm(code)
			code = removeEnum(code, 'USE_CLANG_%w* = 0')
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

	-- depends on <stdio.h> <machine/_types.h>
	{
		inc = '<wchar.h>',
		out = 'OSX/c/wchar.lua',
		final = function(code)
			code = fixasm(code)
			code = removeEnum(code, 'USE_CLANG_%w* = 0')
			-- these are duplicated in <wchar.h> and in <stdint.h>
			code = commentOutLine(code, 'enum { WCHAR_MIN = -2147483648 };')
			code = commentOutLine(code, 'enum { WCHAR_MAX = 2147483647 };')
			return code
		end,
	},

	{
		inc = '<math.h>',
		out = 'OSX/c/math.lua',
		final = function(code)
			-- idk how to handle luajit and _Float16 for now so ...
			code = string.split(code, '\n'):filter(function(l)
				return not l:find'_Float16'
			end):concat'\n'
			return code
		end,
	},

	-- depends on <_types.h>
	{
		inc = '<dirent.h>',
		out = 'OSX/c/dirent.lua',
		final = function(code)
			code = fixasm(code)

			-- how come __BLOCKS__ is defined ...
			-- TODO disable __BLOCKS__ to omit these:
			code = string.split(code, '\n'):filter(function(l)
				return not l:find'_b%('
			end):concat'\n'

			return code
		end,
	},

	-- depends on <_types.h> <sys/signal.h>
	{
		inc = '<signal.h>',
		out = 'OSX/c/signal.lua',
		final = function(code)
			code = fixasm(code)
			code = fixEnumsAndDefineMacrosInterleaved(code)
			return code
		end,
	},

	-- depends on <sys/syslimits.h> <machine/_types.h>
	{inc='<sys/param.h>', out='OSX/c/sys/param.lua', final=function(code)
		code = fixEnumsAndDefineMacrosInterleaved(code)
		return code
	end},

	-- depends on <sys/_types/_timespec.h> <sys/_types/_fd_def.h> <machine/_types.h>
	{
		inc = '<sys/time.h>',
		out = 'OSX/c/sys/time.lua',
		final = function(code)
			code = fixasm(code)
			code = fixEnumsAndDefineMacrosInterleaved(code)
			return code
		end,
	},

	{
		inc = '<complex.h>',
		out = 'OSX/c/complex.lua',
		enumGenUnderscoreMacros = true,
		final = function(code)
			code = commentOutLine(code, 'enum { __BEGIN_DECLS = 1 };')
			code = commentOutLine(code, 'enum { __END_DECLS = 1 };')
			code = commentOutLine(code, 'enum { __const = 0 };')
			code = commentOutLine(code, 'enum { __signed = 0 };')
			code = commentOutLine(code, 'enum { __volatile = 0 };')
			code = commentOutLine(code, 'enum { __restrict = 0 };')
			code = commentOutLine(code, 'enum { complex = 0 };')
			return code
		end,
	},

	--[[ TODO vararg problem
	{
		inc = '<pthread.h>',
		out = 'OSX/c/pthread.lua',
		final = function(code)
			code = fixEnumsAndDefineMacrosInterleaved(code)
			return code
		end,
	},
	--]]

	-- used by GL, GLES1, GLES2 ...
	{
		inc = '"KHR/khrplatform.h"',
		out = 'OSX/KHR/khrplatform.lua',
		includedirs = {'.'},
	},
}:mapi(function(inc)
	inc.os = 'OSX'
	return inc
end))
--]====] End OSX-specific:

includeList:append(table{

-- these come from external libraries (so I don't put them in the c/ subfolder)


	{
		-- ok I either need to have my macros smart-detect when their value is only used for types
		-- or someone needs to rewrite the zlib.h and zconf.h to use `typedef` instead of `#define` when specifying types.
		-- until either happens, I'm copying the zlib locally and changing its `#define` types to `typedef`.
		inc = '"zlib/zlib.h"',
		flags = '-I.',
		out = 'zlib.lua',
		final = function(code)

			-- ... then add some macros onto the end manually
			code = code .. [=[
local wrapper
wrapper = require 'ffi.libwrapper'{
	lib = require 'ffi.load' 'z',
	defs = {},
}

-- macros

wrapper.ZLIB_VERSION = "1.3.1"

function wrapper.zlib_version(...)
	return wrapper.zlibVersion(...)
end

function wrapper.deflateInit(strm)
	return wrapper.deflateInit_(strm, wrapper.ZLIB_VERSION, ffi.sizeof'z_stream')
end

function wrapper.inflateInit(strm)
	return wrapper.inflateInit_(strm, wrapper.ZLIB_VERSION, ffi.sizeof'z_stream')
end

function wrapper.deflateInit2(strm, level, method, windowBits, memLevel, strategy)
	return wrapper.deflateInit2_(strm, level, method, windowBits, memLevel, strategy, wrapper.ZLIB_VERSION, ffi.sizeof'z_stream')
end

function wrapper.inflateInit2(strm, windowBits)
	return wrapper.inflateInit2_(strm, windowBits, wrapper.ZLIB_VERSION, ffi.sizeof'z_stream')
end

function wrapper.inflateBackInit(strm, windowBits, window)
	return wrapper.inflateBackInit_(strm, windowBits, window, wrapper.ZLIB_VERSION, ffi.sizeof'z_stream')
end

-- safe-call wrapper:
function wrapper.pcall(fn, ...)
	local f = assert.index(wrapper, fn)
	local result = f(...)
	if result == wrapper.Z_OK then return true end
	local errs = require 'ext.table'{
		'Z_ERRNO',
		'Z_STREAM_ERROR',
		'Z_DATA_ERROR',
		'Z_MEM_ERROR',
		'Z_BUF_ERROR',
		'Z_VERSION_ERROR',
	}:mapi(function(v) return v, (assert.index(wrapper, v)) end):setmetatable(nil)
	local name = errs[result]
	return false, fn.." failed with error "..result..(name and (' ('..name..')') or ''), result
end

--[[
zlib doesn't provide any mechanism for determining the required size of an uncompressed buffer.
First I thought I'd try-and-fail and look for Z_MEM_ERROR's ... but sometimes you also get other errors like Z_BUF_ERROR.
A solution would be to save the decompressed length alongside the buffer.
From there I could require the caller to save it themselves.  But nah.
Or - what I will do - to keep this a one-stop-shop function -
I will write the decompressed length to the first 8 bytes.
So for C compatability with the resulting data, just skip the first 8 bytes.
--]]
function wrapper.compressLua(src)
	assert.type(src, 'string')
	local srcLen = ffi.new'uint64_t[1]'
	srcLen[0] = #src
	if ffi.sizeof'uLongf' <= 4 and srcLen[0] >= 4294967296ULL then
		error("overflow")
	end
	local dstLen = ffi.new('uLongf[1]', wrapper.compressBound(ffi.cast('uLongf', srcLen[0])))
	local dst = ffi.new('Bytef[?]', dstLen[0])
	assert(wrapper.pcall('compress', dst, dstLen, src, ffi.cast('uLongf', srcLen[0])))

	local srcLenP = ffi.cast('uint8_t*', srcLen)
	local dstAndLen = ''
	for i=0,7 do
		dstAndLen=dstAndLen..string.char(srcLenP[i])
	end
	dstAndLen=dstAndLen..ffi.string(dst, dstLen[0])
	return dstAndLen
end

function wrapper.uncompressLua(srcAndLen)
	assert.type(srcAndLen, 'string')
	-- there's no good way in the zlib api to tell how big this will need to be
	-- so I'm saving it as the first 8 bytes of the data
	local dstLenP = ffi.cast('uint8_t*', srcAndLen)
	local src = dstLenP + 8
	local srcLen = #srcAndLen - 8
	local dstLen = ffi.new'uint64_t[1]'
	dstLen[0] = 0
	for i=7,0,-1 do
		dstLen[0] = bit.bor(bit.lshift(dstLen[0], 8), dstLenP[i])
	end
	if ffi.sizeof'uLongf' <= 4 and dstLen[0] >= 4294967296ULL then
		error("overflow")
	end

	local dst = ffi.new('Bytef[?]', dstLen[0])
	assert(wrapper.pcall('uncompress', dst, ffi.cast('uLongf*', dstLen), src, srcLen))
	return ffi.string(dst, dstLen[0])
end

return wrapper
]=]
			return code
		end,
	},

	-- apt install libffi-dev
	{inc='<ffi.h>', out='libffi.lua', final=function(code)
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
		-- OFF_T is define'd to off_t soo ...
		code = safegsub(code, 'enum { OFF_T = 0 };\n', '')

		-- TODO autogen this from /usr/include/longnam.h
		-- TODO TODO autogen all macro function mappings, not just this one
		code = code .. [=[

-- since macro functions are the weak point of my binding code generator,
-- here's the fitsio longnam.h file contents manually:
local lib = require 'ffi.load' 'cfitsio'
local wrapper = setmetatable({
]=]
		-- store table-of-table so pairs() iterator doesn't rearrange order (for future diff's sake)...
		for _,kv in ipairs{
	--[[ in longnam.h but not in fitsio.h:
			{'fits_parse_output_url', 'ffourl'},
			{'fits_compress_img', 'fits_comp_img'},
	--]]
			{'fits_parse_input_url', 'ffiurl'},
			{'fits_parse_input_filename', 'ffifile'},
			{'fits_parse_rootname', 'ffrtnm'},
			{'fits_file_exists', 'ffexist'},
			{'fits_parse_extspec', 'ffexts'},
			{'fits_parse_extnum', 'ffextn'},
			{'fits_parse_binspec', 'ffbins'},
			{'fits_parse_binrange', 'ffbinr'},
			{'fits_parse_range', 'ffrwrg'},
			{'fits_parse_rangell', 'ffrwrgll'},
			{'fits_open_memfile', 'ffomem'},
			{'fits_open_data', 'ffdopn'},
			{'fits_open_extlist', 'ffeopn'},
			{'fits_open_table', 'fftopn'},
			{'fits_open_image', 'ffiopn'},
			{'fits_open_diskfile', 'ffdkopn'},
			{'fits_reopen_file', 'ffreopen'},
			{'fits_create_file', 'ffinit'},
			{'fits_create_diskfile', 'ffdkinit'},
			{'fits_create_memfile', 'ffimem'},
			{'fits_create_template', 'fftplt'},
			{'fits_flush_file', 'ffflus'},
			{'fits_flush_buffer', 'ffflsh'},
			{'fits_close_file', 'ffclos'},
			{'fits_delete_file', 'ffdelt'},
			{'fits_file_name', 'ffflnm'},
			{'fits_file_mode', 'ffflmd'},
			{'fits_url_type', 'ffurlt'},
			{'fits_get_version', 'ffvers'},
			{'fits_uppercase', 'ffupch'},
			{'fits_get_errstatus', 'ffgerr'},
			{'fits_write_errmsg', 'ffpmsg'},
			{'fits_write_errmark', 'ffpmrk'},
			{'fits_read_errmsg', 'ffgmsg'},
			{'fits_clear_errmsg', 'ffcmsg'},
			{'fits_clear_errmark', 'ffcmrk'},
			{'fits_report_error', 'ffrprt'},
			{'fits_compare_str', 'ffcmps'},
			{'fits_test_keyword', 'fftkey'},
			{'fits_test_record', 'fftrec'},
			{'fits_null_check', 'ffnchk'},
			{'fits_make_keyn', 'ffkeyn'},
			{'fits_make_nkey', 'ffnkey'},
			{'fits_make_key', 'ffmkky'},
			{'fits_get_keyclass', 'ffgkcl'},
			{'fits_get_keytype', 'ffdtyp'},
			{'fits_get_inttype', 'ffinttyp'},
			{'fits_parse_value', 'ffpsvc'},
			{'fits_get_keyname', 'ffgknm'},
			{'fits_parse_template', 'ffgthd'},
			{'fits_ascii_tform', 'ffasfm'},
			{'fits_binary_tform', 'ffbnfm'},
			{'fits_binary_tformll', 'ffbnfmll'},
			{'fits_get_tbcol', 'ffgabc'},
			{'fits_get_rowsize', 'ffgrsz'},
			{'fits_get_col_display_width', 'ffgcdw'},
			{'fits_write_record', 'ffprec'},
			{'fits_write_key', 'ffpky'},
			{'fits_write_key_unit', 'ffpunt'},
			{'fits_write_comment', 'ffpcom'},
			{'fits_write_history', 'ffphis'},
			{'fits_write_date', 'ffpdat'},
			{'fits_get_system_time', 'ffgstm'},
			{'fits_get_system_date', 'ffgsdt'},
			{'fits_date2str', 'ffdt2s'},
			{'fits_time2str', 'fftm2s'},
			{'fits_str2date', 'ffs2dt'},
			{'fits_str2time', 'ffs2tm'},
			{'fits_write_key_longstr', 'ffpkls'},
			{'fits_write_key_longwarn', 'ffplsw'},
			{'fits_write_key_null', 'ffpkyu'},
			{'fits_write_key_str', 'ffpkys'},
			{'fits_write_key_log', 'ffpkyl'},
			{'fits_write_key_lng', 'ffpkyj'},
			{'fits_write_key_ulng', 'ffpkyuj'},
			{'fits_write_key_fixflt', 'ffpkyf'},
			{'fits_write_key_flt', 'ffpkye'},
			{'fits_write_key_fixdbl', 'ffpkyg'},
			{'fits_write_key_dbl', 'ffpkyd'},
			{'fits_write_key_fixcmp', 'ffpkfc'},
			{'fits_write_key_cmp', 'ffpkyc'},
			{'fits_write_key_fixdblcmp', 'ffpkfm'},
			{'fits_write_key_dblcmp', 'ffpkym'},
			{'fits_write_key_triple', 'ffpkyt'},
			{'fits_write_tdim', 'ffptdm'},
			{'fits_write_tdimll', 'ffptdmll'},
			{'fits_write_keys_str', 'ffpkns'},
			{'fits_write_keys_log', 'ffpknl'},
			{'fits_write_keys_lng', 'ffpknj'},
			{'fits_write_keys_fixflt', 'ffpknf'},
			{'fits_write_keys_flt', 'ffpkne'},
			{'fits_write_keys_fixdbl', 'ffpkng'},
			{'fits_write_keys_dbl', 'ffpknd'},
			{'fits_copy_key', 'ffcpky'},
			{'fits_write_imghdr', 'ffphps'},
			{'fits_write_imghdrll', 'ffphpsll'},
			{'fits_write_grphdr', 'ffphpr'},
			{'fits_write_grphdrll', 'ffphprll'},
			{'fits_write_atblhdr', 'ffphtb'},
			{'fits_write_btblhdr', 'ffphbn'},
			{'fits_write_exthdr', 'ffphext'},
			{'fits_write_key_template', 'ffpktp'},
			{'fits_get_hdrspace', 'ffghsp'},
			{'fits_get_hdrpos', 'ffghps'},
			{'fits_movabs_key', 'ffmaky'},
			{'fits_movrel_key', 'ffmrky'},
			{'fits_find_nextkey', 'ffgnxk'},
			{'fits_read_record', 'ffgrec'},
			{'fits_read_card', 'ffgcrd'},
			{'fits_read_str', 'ffgstr'},
			{'fits_read_key_unit', 'ffgunt'},
			{'fits_read_keyn', 'ffgkyn'},
			{'fits_read_key', 'ffgky'},
			{'fits_read_keyword', 'ffgkey'},
			{'fits_read_key_str', 'ffgkys'},
			{'fits_read_key_log', 'ffgkyl'},
			{'fits_read_key_lng', 'ffgkyj'},
			{'fits_read_key_lnglng', 'ffgkyjj'},
			{'fits_read_key_ulnglng', 'ffgkyujj'},
			{'fits_read_key_flt', 'ffgkye'},
			{'fits_read_key_dbl', 'ffgkyd'},
			{'fits_read_key_cmp', 'ffgkyc'},
			{'fits_read_key_dblcmp', 'ffgkym'},
			{'fits_read_key_triple', 'ffgkyt'},
			{'fits_get_key_strlen', 'ffgksl'},
			{'fits_read_key_longstr', 'ffgkls'},
			{'fits_read_string_key', 'ffgsky'},
			{'fits_free_memory', 'fffree'},
			{'fits_read_tdim', 'ffgtdm'},
			{'fits_read_tdimll', 'ffgtdmll'},
			{'fits_decode_tdim', 'ffdtdm'},
			{'fits_decode_tdimll', 'ffdtdmll'},
			{'fits_read_keys_str', 'ffgkns'},
			{'fits_read_keys_log', 'ffgknl'},
			{'fits_read_keys_lng', 'ffgknj'},
			{'fits_read_keys_lnglng', 'ffgknjj'},
			{'fits_read_keys_flt', 'ffgkne'},
			{'fits_read_keys_dbl', 'ffgknd'},
			{'fits_read_imghdr', 'ffghpr'},
			{'fits_read_imghdrll', 'ffghprll'},
			{'fits_read_atblhdr', 'ffghtb'},
			{'fits_read_btblhdr', 'ffghbn'},
			{'fits_read_atblhdrll', 'ffghtbll'},
			{'fits_read_btblhdrll', 'ffghbnll'},
			{'fits_hdr2str', 'ffhdr2str'},
			{'fits_convert_hdr2str', 'ffcnvthdr2str'},
			{'fits_update_card', 'ffucrd'},
			{'fits_update_key', 'ffuky'},
			{'fits_update_key_null', 'ffukyu'},
			{'fits_update_key_str', 'ffukys'},
			{'fits_update_key_longstr', 'ffukls'},
			{'fits_update_key_log', 'ffukyl'},
			{'fits_update_key_lng', 'ffukyj'},
			{'fits_update_key_fixflt', 'ffukyf'},
			{'fits_update_key_flt', 'ffukye'},
			{'fits_update_key_fixdbl', 'ffukyg'},
			{'fits_update_key_dbl', 'ffukyd'},
			{'fits_update_key_fixcmp', 'ffukfc'},
			{'fits_update_key_cmp', 'ffukyc'},
			{'fits_update_key_fixdblcmp', 'ffukfm'},
			{'fits_update_key_dblcmp', 'ffukym'},
			{'fits_modify_record', 'ffmrec'},
			{'fits_modify_card', 'ffmcrd'},
			{'fits_modify_name', 'ffmnam'},
			{'fits_modify_comment', 'ffmcom'},
			{'fits_modify_key_null', 'ffmkyu'},
			{'fits_modify_key_str', 'ffmkys'},
			{'fits_modify_key_longstr', 'ffmkls'},
			{'fits_modify_key_log', 'ffmkyl'},
			{'fits_modify_key_lng', 'ffmkyj'},
			{'fits_modify_key_fixflt', 'ffmkyf'},
			{'fits_modify_key_flt', 'ffmkye'},
			{'fits_modify_key_fixdbl', 'ffmkyg'},
			{'fits_modify_key_dbl', 'ffmkyd'},
			{'fits_modify_key_fixcmp', 'ffmkfc'},
			{'fits_modify_key_cmp', 'ffmkyc'},
			{'fits_modify_key_fixdblcmp', 'ffmkfm'},
			{'fits_modify_key_dblcmp', 'ffmkym'},
			{'fits_insert_record', 'ffirec'},
			{'fits_insert_card', 'ffikey'},
			{'fits_insert_key_null', 'ffikyu'},
			{'fits_insert_key_str', 'ffikys'},
			{'fits_insert_key_longstr', 'ffikls'},
			{'fits_insert_key_log', 'ffikyl'},
			{'fits_insert_key_lng', 'ffikyj'},
			{'fits_insert_key_fixflt', 'ffikyf'},
			{'fits_insert_key_flt', 'ffikye'},
			{'fits_insert_key_fixdbl', 'ffikyg'},
			{'fits_insert_key_dbl', 'ffikyd'},
			{'fits_insert_key_fixcmp', 'ffikfc'},
			{'fits_insert_key_cmp', 'ffikyc'},
			{'fits_insert_key_fixdblcmp', 'ffikfm'},
			{'fits_insert_key_dblcmp', 'ffikym'},
			{'fits_delete_key', 'ffdkey'},
			{'fits_delete_str', 'ffdstr'},
			{'fits_delete_record', 'ffdrec'},
			{'fits_get_hdu_num', 'ffghdn'},
			{'fits_get_hdu_type', 'ffghdt'},
			{'fits_get_hduaddr', 'ffghad'},
			{'fits_get_hduaddrll', 'ffghadll'},
			{'fits_get_hduoff', 'ffghof'},
			{'fits_get_img_param', 'ffgipr'},
			{'fits_get_img_paramll', 'ffgiprll'},
			{'fits_get_img_type', 'ffgidt'},
			{'fits_get_img_equivtype', 'ffgiet'},
			{'fits_get_img_dim', 'ffgidm'},
			{'fits_get_img_size', 'ffgisz'},
			{'fits_get_img_sizell', 'ffgiszll'},
			{'fits_movabs_hdu', 'ffmahd'},
			{'fits_movrel_hdu', 'ffmrhd'},
			{'fits_movnam_hdu', 'ffmnhd'},
			{'fits_get_num_hdus', 'ffthdu'},
			{'fits_create_img', 'ffcrim'},
			{'fits_create_imgll', 'ffcrimll'},
			{'fits_create_tbl', 'ffcrtb'},
			{'fits_create_hdu', 'ffcrhd'},
			{'fits_insert_img', 'ffiimg'},
			{'fits_insert_imgll', 'ffiimgll'},
			{'fits_insert_atbl', 'ffitab'},
			{'fits_insert_btbl', 'ffibin'},
			{'fits_resize_img', 'ffrsim'},
			{'fits_resize_imgll', 'ffrsimll'},
			{'fits_delete_hdu', 'ffdhdu'},
			{'fits_copy_hdu', 'ffcopy'},
			{'fits_copy_file', 'ffcpfl'},
			{'fits_copy_header', 'ffcphd'},
			{'fits_copy_hdutab', 'ffcpht'},
			{'fits_copy_data', 'ffcpdt'},
			{'fits_write_hdu', 'ffwrhdu'},
			{'fits_set_hdustruc', 'ffrdef'},
			{'fits_set_hdrsize', 'ffhdef'},
			{'fits_write_theap', 'ffpthp'},
			{'fits_encode_chksum', 'ffesum'},
			{'fits_decode_chksum', 'ffdsum'},
			{'fits_write_chksum', 'ffpcks'},
			{'fits_update_chksum', 'ffupck'},
			{'fits_verify_chksum', 'ffvcks'},
			{'fits_get_chksum', 'ffgcks'},
			{'fits_set_bscale', 'ffpscl'},
			{'fits_set_tscale', 'fftscl'},
			{'fits_set_imgnull', 'ffpnul'},
			{'fits_set_btblnull', 'fftnul'},
			{'fits_set_atblnull', 'ffsnul'},
			{'fits_get_colnum', 'ffgcno'},
			{'fits_get_colname', 'ffgcnn'},
			{'fits_get_coltype', 'ffgtcl'},
			{'fits_get_coltypell', 'ffgtclll'},
			{'fits_get_eqcoltype', 'ffeqty'},
			{'fits_get_eqcoltypell', 'ffeqtyll'},
			{'fits_get_num_rows', 'ffgnrw'},
			{'fits_get_num_rowsll', 'ffgnrwll'},
			{'fits_get_num_cols', 'ffgncl'},
			{'fits_get_acolparms', 'ffgacl'},
			{'fits_get_bcolparms', 'ffgbcl'},
			{'fits_get_bcolparmsll', 'ffgbclll'},
			{'fits_iterate_data', 'ffiter'},
			{'fits_read_grppar_byt', 'ffggpb'},
			{'fits_read_grppar_sbyt', 'ffggpsb'},
			{'fits_read_grppar_usht', 'ffggpui'},
			{'fits_read_grppar_ulng', 'ffggpuj'},
			{'fits_read_grppar_ulnglng', 'ffggpujj'},
			{'fits_read_grppar_sht', 'ffggpi'},
			{'fits_read_grppar_lng', 'ffggpj'},
			{'fits_read_grppar_lnglng', 'ffggpjj'},
			{'fits_read_grppar_int', 'ffggpk'},
			{'fits_read_grppar_uint', 'ffggpuk'},
			{'fits_read_grppar_flt', 'ffggpe'},
			{'fits_read_grppar_dbl', 'ffggpd'},
			{'fits_read_pix', 'ffgpxv'},
			{'fits_read_pixll', 'ffgpxvll'},
			{'fits_read_pixnull', 'ffgpxf'},
			{'fits_read_pixnullll', 'ffgpxfll'},
			{'fits_read_img', 'ffgpv'},
			{'fits_read_imgnull', 'ffgpf'},
			{'fits_read_img_byt', 'ffgpvb'},
			{'fits_read_img_sbyt', 'ffgpvsb'},
			{'fits_read_img_usht', 'ffgpvui'},
			{'fits_read_img_ulng', 'ffgpvuj'},
			{'fits_read_img_sht', 'ffgpvi'},
			{'fits_read_img_lng', 'ffgpvj'},
			{'fits_read_img_ulnglng', 'ffgpvujj'},
			{'fits_read_img_lnglng', 'ffgpvjj'},
			{'fits_read_img_uint', 'ffgpvuk'},
			{'fits_read_img_int', 'ffgpvk'},
			{'fits_read_img_flt', 'ffgpve'},
			{'fits_read_img_dbl', 'ffgpvd'},
			{'fits_read_imgnull_byt', 'ffgpfb'},
			{'fits_read_imgnull_sbyt', 'ffgpfsb'},
			{'fits_read_imgnull_usht', 'ffgpfui'},
			{'fits_read_imgnull_ulng', 'ffgpfuj'},
			{'fits_read_imgnull_sht', 'ffgpfi'},
			{'fits_read_imgnull_lng', 'ffgpfj'},
			{'fits_read_imgnull_ulnglng', 'ffgpfujj'},
			{'fits_read_imgnull_lnglng', 'ffgpfjj'},
			{'fits_read_imgnull_uint', 'ffgpfuk'},
			{'fits_read_imgnull_int', 'ffgpfk'},
			{'fits_read_imgnull_flt', 'ffgpfe'},
			{'fits_read_imgnull_dbl', 'ffgpfd'},
			{'fits_read_2d_byt', 'ffg2db'},
			{'fits_read_2d_sbyt', 'ffg2dsb'},
			{'fits_read_2d_usht', 'ffg2dui'},
			{'fits_read_2d_ulng', 'ffg2duj'},
			{'fits_read_2d_sht', 'ffg2di'},
			{'fits_read_2d_lng', 'ffg2dj'},
			{'fits_read_2d_ulnglng', 'ffg2dujj'},
			{'fits_read_2d_lnglng', 'ffg2djj'},
			{'fits_read_2d_uint', 'ffg2duk'},
			{'fits_read_2d_int', 'ffg2dk'},
			{'fits_read_2d_flt', 'ffg2de'},
			{'fits_read_2d_dbl', 'ffg2dd'},
			{'fits_read_3d_byt', 'ffg3db'},
			{'fits_read_3d_sbyt', 'ffg3dsb'},
			{'fits_read_3d_usht', 'ffg3dui'},
			{'fits_read_3d_ulng', 'ffg3duj'},
			{'fits_read_3d_sht', 'ffg3di'},
			{'fits_read_3d_lng', 'ffg3dj'},
			{'fits_read_3d_ulnglng', 'ffg3dujj'},
			{'fits_read_3d_lnglng', 'ffg3djj'},
			{'fits_read_3d_uint', 'ffg3duk'},
			{'fits_read_3d_int', 'ffg3dk'},
			{'fits_read_3d_flt', 'ffg3de'},
			{'fits_read_3d_dbl', 'ffg3dd'},
			{'fits_read_subset', 'ffgsv'},
			{'fits_read_subset_byt', 'ffgsvb'},
			{'fits_read_subset_sbyt', 'ffgsvsb'},
			{'fits_read_subset_usht', 'ffgsvui'},
			{'fits_read_subset_ulng', 'ffgsvuj'},
			{'fits_read_subset_sht', 'ffgsvi'},
			{'fits_read_subset_lng', 'ffgsvj'},
			{'fits_read_subset_ulnglng', 'ffgsvujj'},
			{'fits_read_subset_lnglng', 'ffgsvjj'},
			{'fits_read_subset_uint', 'ffgsvuk'},
			{'fits_read_subset_int', 'ffgsvk'},
			{'fits_read_subset_flt', 'ffgsve'},
			{'fits_read_subset_dbl', 'ffgsvd'},
			{'fits_read_subsetnull_byt', 'ffgsfb'},
			{'fits_read_subsetnull_sbyt', 'ffgsfsb'},
			{'fits_read_subsetnull_usht', 'ffgsfui'},
			{'fits_read_subsetnull_ulng', 'ffgsfuj'},
			{'fits_read_subsetnull_sht', 'ffgsfi'},
			{'fits_read_subsetnull_lng', 'ffgsfj'},
			{'fits_read_subsetnull_ulnglng', 'ffgsfujj'},
			{'fits_read_subsetnull_lnglng', 'ffgsfjj'},
			{'fits_read_subsetnull_uint', 'ffgsfuk'},
			{'fits_read_subsetnull_int', 'ffgsfk'},
			{'fits_read_subsetnull_flt', 'ffgsfe'},
			{'fits_read_subsetnull_dbl', 'ffgsfd'},
			{'ffcpimg', 'fits_copy_image_section'},
			{'fits_decompress_img', 'fits_decomp_img'},
			{'fits_read_col', 'ffgcv'},
			{'fits_read_cols', 'ffgcvn'},
			{'fits_read_colnull', 'ffgcf'},
			{'fits_read_col_str', 'ffgcvs'},
			{'fits_read_col_log', 'ffgcvl'},
			{'fits_read_col_byt', 'ffgcvb'},
			{'fits_read_col_sbyt', 'ffgcvsb'},
			{'fits_read_col_usht', 'ffgcvui'},
			{'fits_read_col_ulng', 'ffgcvuj'},
			{'fits_read_col_sht', 'ffgcvi'},
			{'fits_read_col_lng', 'ffgcvj'},
			{'fits_read_col_ulnglng', 'ffgcvujj'},
			{'fits_read_col_lnglng', 'ffgcvjj'},
			{'fits_read_col_uint', 'ffgcvuk'},
			{'fits_read_col_int', 'ffgcvk'},
			{'fits_read_col_flt', 'ffgcve'},
			{'fits_read_col_dbl', 'ffgcvd'},
			{'fits_read_col_cmp', 'ffgcvc'},
			{'fits_read_col_dblcmp', 'ffgcvm'},
			{'fits_read_col_bit', 'ffgcx'},
			{'fits_read_col_bit_usht', 'ffgcxui'},
			{'fits_read_col_bit_uint', 'ffgcxuk'},
			{'fits_read_colnull_str', 'ffgcfs'},
			{'fits_read_colnull_log', 'ffgcfl'},
			{'fits_read_colnull_byt', 'ffgcfb'},
			{'fits_read_colnull_sbyt', 'ffgcfsb'},
			{'fits_read_colnull_usht', 'ffgcfui'},
			{'fits_read_colnull_ulng', 'ffgcfuj'},
			{'fits_read_colnull_sht', 'ffgcfi'},
			{'fits_read_colnull_lng', 'ffgcfj'},
			{'fits_read_colnull_ulnglng', 'ffgcfujj'},
			{'fits_read_colnull_lnglng', 'ffgcfjj'},
			{'fits_read_colnull_uint', 'ffgcfuk'},
			{'fits_read_colnull_int', 'ffgcfk'},
			{'fits_read_colnull_flt', 'ffgcfe'},
			{'fits_read_colnull_dbl', 'ffgcfd'},
			{'fits_read_colnull_cmp', 'ffgcfc'},
			{'fits_read_colnull_dblcmp', 'ffgcfm'},
			{'fits_read_descript', 'ffgdes'},
			{'fits_read_descriptll', 'ffgdesll'},
			{'fits_read_descripts', 'ffgdess'},
			{'fits_read_descriptsll', 'ffgdessll'},
			{'fits_read_tblbytes', 'ffgtbb'},
			{'fits_write_grppar_byt', 'ffpgpb'},
			{'fits_write_grppar_sbyt', 'ffpgpsb'},
			{'fits_write_grppar_usht', 'ffpgpui'},
			{'fits_write_grppar_ulng', 'ffpgpuj'},
			{'fits_write_grppar_sht', 'ffpgpi'},
			{'fits_write_grppar_lng', 'ffpgpj'},
			{'fits_write_grppar_ulnglng', 'ffpgpujj'},
			{'fits_write_grppar_lnglng', 'ffpgpjj'},
			{'fits_write_grppar_uint', 'ffpgpuk'},
			{'fits_write_grppar_int', 'ffpgpk'},
			{'fits_write_grppar_flt', 'ffpgpe'},
			{'fits_write_grppar_dbl', 'ffpgpd'},
			{'fits_write_pix', 'ffppx'},
			{'fits_write_pixll', 'ffppxll'},
			{'fits_write_pixnull', 'ffppxn'},
			{'fits_write_pixnullll', 'ffppxnll'},
			{'fits_write_img', 'ffppr'},
			{'fits_write_img_byt', 'ffpprb'},
			{'fits_write_img_sbyt', 'ffpprsb'},
			{'fits_write_img_usht', 'ffpprui'},
			{'fits_write_img_ulng', 'ffppruj'},
			{'fits_write_img_sht', 'ffppri'},
			{'fits_write_img_lng', 'ffpprj'},
			{'fits_write_img_ulnglng', 'ffpprujj'},
			{'fits_write_img_lnglng', 'ffpprjj'},
			{'fits_write_img_uint', 'ffppruk'},
			{'fits_write_img_int', 'ffpprk'},
			{'fits_write_img_flt', 'ffppre'},
			{'fits_write_img_dbl', 'ffpprd'},
			{'fits_write_imgnull', 'ffppn'},
			{'fits_write_imgnull_byt', 'ffppnb'},
			{'fits_write_imgnull_sbyt', 'ffppnsb'},
			{'fits_write_imgnull_usht', 'ffppnui'},
			{'fits_write_imgnull_ulng', 'ffppnuj'},
			{'fits_write_imgnull_sht', 'ffppni'},
			{'fits_write_imgnull_lng', 'ffppnj'},
			{'fits_write_imgnull_ulnglng', 'ffppnujj'},
			{'fits_write_imgnull_lnglng', 'ffppnjj'},
			{'fits_write_imgnull_uint', 'ffppnuk'},
			{'fits_write_imgnull_int', 'ffppnk'},
			{'fits_write_imgnull_flt', 'ffppne'},
			{'fits_write_imgnull_dbl', 'ffppnd'},
			{'fits_write_img_null', 'ffppru'},
			{'fits_write_null_img', 'ffpprn'},
			{'fits_write_2d_byt', 'ffp2db'},
			{'fits_write_2d_sbyt', 'ffp2dsb'},
			{'fits_write_2d_usht', 'ffp2dui'},
			{'fits_write_2d_ulng', 'ffp2duj'},
			{'fits_write_2d_sht', 'ffp2di'},
			{'fits_write_2d_lng', 'ffp2dj'},
			{'fits_write_2d_ulnglng', 'ffp2dujj'},
			{'fits_write_2d_lnglng', 'ffp2djj'},
			{'fits_write_2d_uint', 'ffp2duk'},
			{'fits_write_2d_int', 'ffp2dk'},
			{'fits_write_2d_flt', 'ffp2de'},
			{'fits_write_2d_dbl', 'ffp2dd'},
			{'fits_write_3d_byt', 'ffp3db'},
			{'fits_write_3d_sbyt', 'ffp3dsb'},
			{'fits_write_3d_usht', 'ffp3dui'},
			{'fits_write_3d_ulng', 'ffp3duj'},
			{'fits_write_3d_sht', 'ffp3di'},
			{'fits_write_3d_lng', 'ffp3dj'},
			{'fits_write_3d_ulnglng', 'ffp3dujj'},
			{'fits_write_3d_lnglng', 'ffp3djj'},
			{'fits_write_3d_uint', 'ffp3duk'},
			{'fits_write_3d_int', 'ffp3dk'},
			{'fits_write_3d_flt', 'ffp3de'},
			{'fits_write_3d_dbl', 'ffp3dd'},
			{'fits_write_subset', 'ffpss'},
			{'fits_write_subset_byt', 'ffpssb'},
			{'fits_write_subset_sbyt', 'ffpsssb'},
			{'fits_write_subset_usht', 'ffpssui'},
			{'fits_write_subset_ulng', 'ffpssuj'},
			{'fits_write_subset_sht', 'ffpssi'},
			{'fits_write_subset_lng', 'ffpssj'},
			{'fits_write_subset_ulnglng', 'ffpssujj'},
			{'fits_write_subset_lnglng', 'ffpssjj'},
			{'fits_write_subset_uint', 'ffpssuk'},
			{'fits_write_subset_int', 'ffpssk'},
			{'fits_write_subset_flt', 'ffpsse'},
			{'fits_write_subset_dbl', 'ffpssd'},
			{'fits_write_col', 'ffpcl'},
			{'fits_write_cols', 'ffpcln'},
			{'fits_write_col_str', 'ffpcls'},
			{'fits_write_col_log', 'ffpcll'},
			{'fits_write_col_byt', 'ffpclb'},
			{'fits_write_col_sbyt', 'ffpclsb'},
			{'fits_write_col_usht', 'ffpclui'},
			{'fits_write_col_ulng', 'ffpcluj'},
			{'fits_write_col_sht', 'ffpcli'},
			{'fits_write_col_lng', 'ffpclj'},
			{'fits_write_col_ulnglng', 'ffpclujj'},
			{'fits_write_col_lnglng', 'ffpcljj'},
			{'fits_write_col_uint', 'ffpcluk'},
			{'fits_write_col_int', 'ffpclk'},
			{'fits_write_col_flt', 'ffpcle'},
			{'fits_write_col_dbl', 'ffpcld'},
			{'fits_write_col_cmp', 'ffpclc'},
			{'fits_write_col_dblcmp', 'ffpclm'},
			{'fits_write_col_null', 'ffpclu'},
			{'fits_write_col_bit', 'ffpclx'},
			{'fits_write_nulrows', 'ffprwu'},
			{'fits_write_nullrows', 'ffprwu'},
			{'fits_write_colnull', 'ffpcn'},
			{'fits_write_colnull_str', 'ffpcns'},
			{'fits_write_colnull_log', 'ffpcnl'},
			{'fits_write_colnull_byt', 'ffpcnb'},
			{'fits_write_colnull_sbyt', 'ffpcnsb'},
			{'fits_write_colnull_usht', 'ffpcnui'},
			{'fits_write_colnull_ulng', 'ffpcnuj'},
			{'fits_write_colnull_sht', 'ffpcni'},
			{'fits_write_colnull_lng', 'ffpcnj'},
			{'fits_write_colnull_ulnglng', 'ffpcnujj'},
			{'fits_write_colnull_lnglng', 'ffpcnjj'},
			{'fits_write_colnull_uint', 'ffpcnuk'},
			{'fits_write_colnull_int', 'ffpcnk'},
			{'fits_write_colnull_flt', 'ffpcne'},
			{'fits_write_colnull_dbl', 'ffpcnd'},
			{'fits_write_ext', 'ffpextn'},
			{'fits_read_ext', 'ffgextn'},
			{'fits_write_descript', 'ffpdes'},
			{'fits_compress_heap', 'ffcmph'},
			{'fits_test_heap', 'fftheap'},
			{'fits_write_tblbytes', 'ffptbb'},
			{'fits_insert_rows', 'ffirow'},
			{'fits_delete_rows', 'ffdrow'},
			{'fits_delete_rowrange', 'ffdrrg'},
			{'fits_delete_rowlist', 'ffdrws'},
			{'fits_delete_rowlistll', 'ffdrwsll'},
			{'fits_insert_col', 'fficol'},
			{'fits_insert_cols', 'fficls'},
			{'fits_delete_col', 'ffdcol'},
			{'fits_copy_col', 'ffcpcl'},
			{'fits_copy_cols', 'ffccls'},
			{'fits_copy_rows', 'ffcprw'},
			{'fits_copy_selrows', 'ffcpsr'},
			{'fits_modify_vector_len', 'ffmvec'},
			{'fits_read_img_coord', 'ffgics'},
			{'fits_read_img_coord_version', 'ffgicsa'},
			{'fits_read_tbl_coord', 'ffgtcs'},
			{'fits_pix_to_world', 'ffwldp'},
			{'fits_world_to_pix', 'ffxypx'},
			{'fits_get_image_wcs_keys', 'ffgiwcs'},
			{'fits_get_table_wcs_keys', 'ffgtwcs'},
			{'fits_find_rows', 'fffrow'},
			{'fits_find_first_row', 'ffffrw'},
			{'fits_find_rows_cmp', 'fffrwc'},
			{'fits_select_rows', 'ffsrow'},
			{'fits_calc_rows', 'ffcrow'},
			{'fits_calculator', 'ffcalc'},
			{'fits_calculator_rng', 'ffcalc_rng'},
			{'fits_test_expr', 'fftexp'},
			{'fits_create_group', 'ffgtcr'},
			{'fits_insert_group', 'ffgtis'},
			{'fits_change_group', 'ffgtch'},
			{'fits_remove_group', 'ffgtrm'},
			{'fits_copy_group', 'ffgtcp'},
			{'fits_merge_groups', 'ffgtmg'},
			{'fits_compact_group', 'ffgtcm'},
			{'fits_verify_group', 'ffgtvf'},
			{'fits_open_group', 'ffgtop'},
			{'fits_add_group_member', 'ffgtam'},
			{'fits_get_num_members', 'ffgtnm'},
			{'fits_get_num_groups', 'ffgmng'},
			{'fits_open_member', 'ffgmop'},
			{'fits_copy_member', 'ffgmcp'},
			{'fits_transfer_member', 'ffgmtf'},
			{'fits_remove_member', 'ffgmrm'},
			{'fits_init_https', 'ffihtps'},
			{'fits_cleanup_https', 'ffchtps'},
			{'fits_verbose_https', 'ffvhtps'},
			{'fits_show_download_progress', 'ffshdwn'},
			{'fits_get_timeout', 'ffgtmo'},
			{'fits_set_timeout', 'ffstmo'},
		} do
			local new, old = table.unpack(kv)
			code = removeEnum(code, new..' = 0')
			code = code .. '\t' .. new .. ' = lib.' .. old .. ',\n'
		end

		-- last one on the list with atypical args:
		code = code .. [=[
	fits_open_file = function(...)
		return lib.ffopentest(lib.CFITSIO_SONAME, ...)
	end,
}, {
	__index = lib
})
return wrapper
]=]
		return code
	end},

	-- apt install libnetcdf-dev
	{inc='<netcdf.h>', out='netcdf.lua', flags=pkgconfigFlags'netcdf', final=function(code)
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
		flags = pkgconfigFlags'hdf5',
		final = function(code)
			-- old header comment:
				-- for gcc / ubuntu looks like off_t is defined in either unistd.h or stdio.h, and either are set via testing/setting __off_t_defined
				-- in other words, the defs in here are getting more and more conditional ...
				-- pretty soon a full set of headers + full preprocessor might be necessary
				-- TODO regen this on Windows and compare?
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
		flags = '-I/usr/local/include/imgui-1.90.5dock -DCIMGUI_DEFINE_ENUMS_AND_STRUCTS',
		out = 'cimgui.lua',
		final = function(code)
			-- this is already in SDL
			code = safegsub(code,
				string.patescape'struct SDL_Window;'..'\n'
				..string.patescape'struct SDL_Renderer;'..'\n'
				..string.patescape'struct _SDL_GameController;'..'\n'
				..string.patescape'typedef union SDL_Event SDL_Event;',

				-- simultaneously insert require to ffi/sdl.lua
				"]] require 'ffi.req' 'sdl2' ffi.cdef[["
			)

			-- looks like in the backend file there's one default parameter value ...
			code = safegsub(code, 'glsl_version = nullptr', 'glsl_version')

			code = safegsub(code, 'enum ImGui_ImplSDL2_GamepadMode {([^}]-)};', 'typedef enum {%1} ImGui_ImplSDL2_GamepadMode;')
			code = safegsub(code, string.patescape'manual_gamepads_array = ((void *)0)', 'manual_gamepads_array')
			code = safegsub(code, string.patescape'manual_gamepads_count = -1', 'manual_gamepads_count')

			code = code .. [[
return require 'ffi.load' 'cimgui_sdl'
]]
			return code
		end,
	},

	{
		inc = '<CL/opencl.h>',
		out = 'OpenCL.lua',
		final = function(code)
			code = commentOutLine(code, 'warning: Need to implement some method to align data here')

			-- ok because I have more than one inc, the second inc points back to the first, and so we do create a self-reference
			-- so fix it here:
			--code = safegsub(code, string.patescape"]] require 'ffi.req' 'OpenCL' ffi.cdef[[\n", "")

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
		flags = pkgconfigFlags'libtiff-4',
		final = function(code)
			-- TODO remove ((deprecated))
			-- TODO remove __attribute__() after functions
			return code
		end,
	},

	-- apt install libjpeg-turbo-dev
	-- linux is using 2.1.2 which generates no different than 2.0.3
	--  based on apt package libturbojpeg0-dev
	-- windows is using 2.0.4 just because 2.0.3 and cmake is breaking for msvc
	{
		inc = '<jpeglib.h>',
		--[[ os-specific?  I unified it in the lua-ffi-bindings repo ...
		out = ffi.os..'/jpeg.lua',
		os = ffi.os,
		--]]
		-- [[
		out = 'jpeg.lua',
		--]
		final = function(code)
			return makeLibWrapper{
				code = code,
				libname = 'jpeg',
				insertRequires = {
					"require 'ffi.req' 'c.stdio'	-- for FILE, even though jpeglib.h itself never includes <stdio.h> ... hmm ...",

					-- I guess I have to hard-code the OS-specific typedef stuff that goes in the header ...
					-- and then later gsub out these typedefs in each OS that generates it...
					[=[

-- TODO does this discrepency still exist in Windows' LibJPEG Turbo 3.0.4 ?
if ffi.os == 'Windows' then
	ffi.cdef[[
typedef unsigned char boolean;
typedef signed int INT32;
]]
else
	ffi.cdef[[
typedef long INT32;
typedef int boolean;
]]
end
]=]
				},
				footerCode = [[

-- these are #define's in jpeglib.h

wrapper.LIBJPEG_TURBO_VERSION = '3.0.4'

function wrapper.jpeg_create_compress(cinfo)
	return wrapper.jpeg_CreateCompress(cinfo, wrapper.JPEG_LIB_VERSION, ffi.sizeof'struct jpeg_compress_struct')
end

function wrapper.jpeg_create_decompress(cinfo)
	return wrapper.jpeg_CreateDecompress(cinfo, wrapper.JPEG_LIB_VERSION, ffi.sizeof'struct jpeg_decompress_struct')
end
]]
			}
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

	-- inc is put last before flags
	-- but inc is what the make.lua uses
	-- so this has to be built make.lua GL/glext.h
	-- but that wont work either cuz that will make the include to GL/glext.h into a split out file (maybe it should be?)
	-- for Windows I've got my glext.h outside the system paths, so you have to add that to the system path location.
	-- notice that GL/glext.h depends on GLenum to be defined.  but gl.h include glext.h.  why.
	{
		inc =
		--[[ OSX ... but I'm putting it in local space cuz bleh framework namespace resolution means include pattern-matching, not appending like typical search paths use ... so until fixing the include resolution ...
			ffi.os == 'OSX' and '"OpenGL/gl.h"' or
		--]] -- osx brew mesa usees GL/gl.h instead of the crappy builtin OSX GL
			'<GL/gl.h>',
		moreincs =
		--[[
			ffi.os == 'OSX' and {'"OpenGL/glext.h"'} or
		--]]
			{'<GL/glext.h>'},
		--[[
		includedirs = ffi.os == 'OSX' and {'.'} or nil,
		--]]
		flags = '-DGL_GLEXT_PROTOTYPES',
		out = ffi.os..'/OpenGL.lua',
		os = ffi.os,
		--[[ TODO -framework equivalent ...
		includeDirMapping = ffi.os == 'OSX' and {
			{['^OpenGL/(.*)$'] = '/Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk/System/Library/Frameworks/OpenGL.framework/Versions/A/Headers/%1'},
		} or nil,
		--]]	-- or not now that I'm using osx brew mesa instead of builtin crappy GL
		skipincs = ffi.os == 'Windows' and {
		-- trying to find out why my gl.h is blowing up on windows
			'<winapifamily.h>',	-- verify please
			'<sdkddkver.h>',
			'<excpt.h>',
			--'<windef.h>',
			--'<minwindef.h>',
			--'<winbase.h>',
			'<windows.h>',
			--'<minwindef.h>',
			'<winnt.h>',
			'<winerror.h>',
			'<stdarg.h>',
			'<specstrings.h>',
			'<apiset.h>',
			'<debugapi.h>',
		} or {},
		macros = ffi.os == 'Windows' and {
			'WINGDIAPI=',
			'APIENTRY=',
		} or nil,
		final = function(code)
			if ffi.os == 'Windows' then
				-- TODO this won't work now that I'm separating out KHRplatform.h ...
				local oldcode = code
				code = "local code = ''\n"
				code = code .. safegsub(oldcode,
					string.patescape'ffi.cdef',
					'code = code .. '
				)
				code = code .. [[
ffi.cdef(code)
local gl = require 'ffi.load' 'GL'
return setmetatable({
	code = code,	-- Windows GLApp needs to be able to read the ffi.cdef string for parsing out wglGetProcAddress's
}, {__index=gl})
]]
			else
				code = code .. [[
return require 'ffi.load' 'GL'
]]
			end
			return code
		end,
	},

	{
		inc = '<lua.h>',
		moreincs = {'<lualib.h>', '<lauxlib.h>'},
		out = 'lua.lua',
		flags = pkgconfigFlags'lua',
		final = function(code)
			code = [[
]] .. code .. [[
return require 'ffi.load' 'lua'
]]
			return code
		end,
	},

	-- depends on complex.h
	{inc='<cblas.h>', out='cblas.lua', final=function(code)
		code = [[
]] .. code .. [[
return require 'ffi.load' 'openblas'
]]
		return code
	end},

	{
		inc = '<lapack.h>',
		out = 'lapack.lua',
		flags = pkgconfigFlags'lapack',
		final = function(code)
			-- needs lapack_int replaced with int, except the enum def line
			-- the def is conditional, but i think this is the right eval ...
			code = safegsub(code, 'enum { lapack_int = 0 };', 'typedef int32_t lapack_int;')
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
			code = safegsub(code, 'enum { LAPACK_[_%w]+ = 0 };', '')
			code = safegsub(code, '\n\n', '\n')

			code = code .. [[
return require 'ffi.load' 'lapack'
]]
			return code
		end,
	},

	{
		inc = '<lapacke.h>',
		out = 'lapacke.lua',
		flags = pkgconfigFlags'lapacke',
		final = function(code)
			code = code .. [[
return require 'ffi.load' 'lapacke'
]]
		return code
		end,
	},

	-- libzip-dev
	-- TODO #define ZIP_OPSYS_* is hex values, should be enums, but they are being commented out ...
	-- because they have 'u' suffixes
	-- same with some other windows #defines
	-- any that have u i etc i32 i64 etc are being failed by my parser.
	{inc='<zip.h>', out='zip.lua', final=function(code)
		code = code .. [[
return require 'ffi.load' 'zip'
]]
		return code
	end},

	-- produces an "int void" because macro arg-expansion covers already-expanded macro-args
	{inc='<png.h>', out='png.lua', final=function(code)
		-- TODO remove contents of pnglibconf.h, or at least the PNG_*_SUPPORTED macros

		-- still working out macro bugs ... if macro expands arg A then I don't want it to expand arg B
		code = safegsub(code, 'int void', 'int type');

		code = code .. [[
return require 'ffi.load' 'png'
]]
		return code
	end},

	-- TODO STILL
	-- looks like atm i'm using a hand-rolled sdl anyways
	--[[
TODO:
sdl.h
- comment out: 'enum { SDLCALL = 1 };'
- comment out: 'enum { SDL_INLINE = 0 };'
- comment out: 'enum { SDL_HAS_FALLTHROUGH = 0 };'
- comment out: 'enum { SIZEOF_VOIDP = 8 };'
- comment out: 'enum { STDC_HEADERS = 1 };'
- comment out: 'enum { HAVE_.* = 1 };'
- comment out: 'enum { SDL_.*_h_ = 1 };'
- comment out: ... just do everything in SDL_config.h
- comment out: ... everything in float.h
	SDL_PRINTF_FORMAT_STRING
	SDL_SCANF_FORMAT_STRING
	DUMMY_ENUM_VALUE
	SDLMAIN_DECLSPEC
	SDL_FUNCTION
	SDL_FILE
	SDL_LINE
	SDL_NULL_WHILE_LOOP_CONDITION
	SDL_assert_state
	SDL_assert_data
	SDL_LIL_ENDIAN
	SDL_BIG_ENDIAN
	SDL_BYTEORDER
	SDL_FLOATWORDORDER
	HAS_BUILTIN_*
	HAS_BROKEN_.*
	SDL_SwapFloat function
	SDL_MUTEX_TIMEOUT
	SDL_RWOPS_*
	RW_SEEK_*
	AUDIO_*
	SDL_Colour
	SDL_BlitSurface
	SDL_BlitScaled
... can't use blanket comment of *_h because of sdl keycode enum define
but you can in i think all other files ...
also HDF5 has a lot of unused enums ...
	--]]
	{
		inc = '<SDL2/SDL.h>',
		out = 'sdl2.lua',
		flags = pkgconfigFlags'sdl2',
		includedirs = ({
			Windows = {[[C:\Users\Chris\include\SDL2]]},
			OSX = {[[/usr/local/Cellar/sdl2/2.32.4/include/SDL2/]]},
		})[ffi.os],
		skipincs = (ffi.os == 'Windows' or ffi.os == 'OSX') and {'<immintrin.h>'} or {},
		silentincs = (ffi.os == 'Windows' or ffi.os == 'OSX') and {} or {'<immintrin.h>'},
		final = function(code)
			code = commentOutLine(code, 'enum { SDL_begin_code_h = 1 };')

			-- TODO comment out SDL2/SDL_config.h ... or just put it in silentincs ?
			-- same with float.h

			-- TODO evaluate this and insert it correctly?
			code = code .. [=[
ffi.cdef[[
// these aren't being generated correctly so here they are:
enum { SDL_WINDOWPOS_UNDEFINED = 0x1FFF0000u };
enum { SDL_WINDOWPOS_CENTERED = 0x2FFF0000u };
]]
]=]

			code = code .. [[
return require 'ffi.load' 'SDL2'
]]
			return code
		end,
	},

	{
		inc = '<SDL3/SDL.h>',
		out = 'sdl3.lua',
		flags = pkgconfigFlags'sdl3',
		includedirs = ({
			Windows = {[[C:\Users\Chris\include\SDL3]]},
			OSX = {[[/usr/local/Cellar/sdl2/3.2.10/include/SDL3/]]},
		})[ffi.os],
		skipincs = (ffi.os == 'Windows' or ffi.os == 'OSX') and {'<immintrin.h>'} or {},
		silentincs = (ffi.os == 'Windows' or ffi.os == 'OSX') and {} or {'<immintrin.h>'},
		final = function(code)
			code = commentOutLine(code, 'enum { SDL_begin_code_h = 1 };')

			-- TODO comment out SDL3/SDL_config.h ... or just put it in silentincs ?
			-- same with float.h

			-- TODO evaluate this and insert it correctly?
			code = code .. [=[
ffi.cdef[[
// these aren't being generated correctly so here they are:
enum { SDL_WINDOWPOS_UNDEFINED = 0x1FFF0000u };
enum { SDL_WINDOWPOS_CENTERED = 0x2FFF0000u };
]]
]=]

			code = code .. [[
return require 'ffi.load' 'SDL3'
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
		flags = '-I/usr/include/vorbis -I/usr/local/include/vorbis',
		final = function(code)
			-- the result contains some inline static functions and some static struct initializers which ffi cdef can't handle
			-- ... I need to comment it out *HERE*.
			code = safegsub(code, 'static int _ov_header_fseek_wrap%b()%b{}', '')
			code = safegsub(code, 'static ov_callbacks OV_CALLBACKS_[_%w]+ = %b{};', '')

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
		inc = ffi.os ~= 'OSX'
			and '<AL/al.h>'
			or '"OpenAL/OpenAL.h"',	-- bleh too tired to go through the same struggles as with OpenGL on OSX ...
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

	{
		inc = '<Python.h>',
		out = 'python.lua',
		-- -I/usr/include/python3.11 -I/usr/include/x86_64-linux-gnu/python3.11
		flags = '-D__NO_INLINE__ -DPIL_NO_INLINE '..(pkgconfigFlags'python3' or ''),
	},

--[=[	TODO how about a flag for skipping a package in `make.lua all` ?
	{
		inc = '<mono/jit/jit.h>',
		out = 'mono.lua',
		flags = pkgconfigFlags'mono-2',
		final = function(code)
			-- enums are ints right ... ?
			code = safegsub(code, 'typedef (enum %b{})%s*([_%a][_%w]*);', '%1; typedef int %2;')
			-- these are interleaved in another enum ...
			code = safegsub(code, 'enum { MONO_TABLE_LAST = 0 };', ' ')
			code = safegsub(code, 'enum { MONO_TABLE_NUM = 1 };', ' ')
			-- pkg-config --libs mono-2
			-- -L/usr/lib/pkgconfig/../../lib -lmono-2.0 -lm -lrt -ldl -lpthread
			-- return require 'ffi.load' 'mono-2.0' ... failed to find it
			-- return require 'ffi.load' '/usr/lib/libmono-2.0.so' ... /usr/lib/libmono-2.0.so: undefined symbol: _ZTIPi
			code = code .. [[
ffi.load('/usr/lib/x86_64-linux-gnu/libstdc++.so.6', true)
return ffi.load '/usr/lib/libmono-2.0.so'
]]
			return code
		end,
	},
--]=]

	{
		inc = '<pulse/pulseaudio.h>',
		out = 'pulse.lua',
		final = function(code)
			-- so this spits out enums for both enums and #define's
			-- that runs us into trouble sometimes ...
			local lines = string.split(code, '\n')
			local definedEnums = {}
			for i=1,#lines do
				local line = lines[i]
				if line:match'^typedef enum' then
					for w in line:gmatch'%S+' do
						if w:match'^PA_' then
							if w:match',$' then w = w:sub(1,-2) end
--io.stderr:write('defining typedef enum '..w..'\n')
							definedEnums[w] = true
						end
					end
				end
				local prefix, enumName = line:match'^(.*)enum { (.*) = 0 };$'
				if enumName then
--io.stderr:write('found enum=0 name '..enumName..'\n')
					if definedEnums[enumName] then
--io.stderr:write('...removing\n')
						lines[i] = prefix
					end
				end
			end
			code = lines:concat'\n'
			-- undefs of static inline functions ...
			for f in ([[PA_CONTEXT_IS_GOOD PA_STREAM_IS_GOOD PA_SINK_IS_OPENED PA_SOURCE_IS_OPENED]]):gmatch'%S+' do
				code = removeStaticInlineFunction(code, f)
				code = safegsub(code, 'enum { '..f..' = 0 };', '')
			end
			return code
		end,
	},

	{
		inc = '<vulkan/vulkan_core.h>',
		flags = '-I/usr/include/vulkan -I/usr/include/vk_video',
		out = 'vulkan.lua',
		final = function(code)
			local postdefs = table()
			code = code:gsub('static const (%S+) (%S+) = ([0-9x]+)ULL;\n',
				-- some of these rae 64bit numbers ... I should put them in lua tables as uint64_t's
				--'enum { %2 = %3 };'
				function(ctype, name, value)
					postdefs:insert(name.." = ffi.new('"..ctype.."', "..value..")")
					return ''
				end
			)
			code = code .. '\n'
				.."local lib = require 'ffi.load' 'vulkan'\n"
				.."return setmetatable({\n"
				..postdefs:mapi(function(l) return '\t'..l..',' end):concat'\n'..'\n'
				.."}, {__index=lib})\n"
			return code
		end,
	},

	-- based on some c bindings I wrote for https://github.com/dacap/clip
	-- which maybe I should also put on github ...
	{
		inc = '<cclip.h>',
		out = 'cclip.lua',
		final = function(code)
			code = code .. '\n'
				.."return require 'ffi.load' 'clip'\n"
			return code
		end,
	},

	{	-- libelf
		inc = '<gelf.h>',		-- gelf.h -> libelf.h -> elf.h
		moreincs = {
			'<elfutils/version.h>',
			'<elfutils/elf-knowledge.h>',
		},
		-- there's also elfutils/elf-knowledge.h and elfutils/version.h ...
		out = 'elf.lua',
		final = function(code)
			-- #define ELF_F_DIRTY ELF_F_DIRTY before enum ELF_F_DIRTY causes this:
			code = removeEnum(code, 'ELF_F_DIRTY = 0')
			code = removeEnum(code, 'ELF_F_LAYOUT = 0')
			code = removeEnum(code, 'ELF_F_PERMISSIVE = 0')
			code = removeEnum(code, 'ELF_CHF_FORCE = 0')
			code = code .. '\n'
				.."return require 'ffi.load' 'elf'\n"
			return code
		end,
	},

	{
		inc = '<tensorflow/c/c_api.h>',
		out = 'tensorflow.lua',
		-- tensorflow is failing when it includes <string.h>, which is funny because I already generate <string.h> above
		-- something in it is pointing to <secure/_string.h>, which is redefining memcpy ... which is breaking my parser (tho it shouldnt break, but i don't want to fix it)
		skipincs = (ffi.os == 'OSX') and {'<string.h>'} or {},
		final = function(code)
			code = code .. [[
return require 'ffi.load' 'tensorflow'
]]
			return code
		end,
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

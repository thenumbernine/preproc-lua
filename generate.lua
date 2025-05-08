#!/usr/bin/env luajit
local ffi = require 'ffi'		-- used for OS check and used for verifying that the generated C headers are luajit-ffi compatible
local table = require 'ext.table'
local string = require 'ext.string'
local io = require 'ext.io'
local os = require 'ext.os'
local tolua = require 'ext.tolua'

local Preproc = require 'preproc'
local ThisPreproc = Preproc:subclass()

-- this is assigned below when args are processed
local incfiles

-- [===============[ begin the code for injecting require()'s to previously-generated luajit files


local includeList = require 'include-list'

-- remove all those that pertain to other os/arch
includeList = includeList:filter(function(inc)
	if inc.os ~= nil and inc.os ~= ffi.os then return end
	if inc.arch ~= nil and inc.arch ~= ffi.arch then return end
	return true
end)

-- 1) store the search => found include names, then
function ThisPreproc:getIncludeFileCode(fn, search, sys)
	self.mapFromIncludeToSearchFile
		= self.mapFromIncludeToSearchFile
		or {}
	if sys then
		self.mapFromIncludeToSearchFile[fn] = '<'..search..'>'
	else
		self.mapFromIncludeToSearchFile[fn] = '"'..search..'"'
	end
	return ThisPreproc.super.getIncludeFileCode(self, fn, search, sys)
end

-- 2) do a final pass replacing the BEGIN/END's of the found names
function ThisPreproc:__call(...)
	local code = ThisPreproc.super.__call(self, ...)
	local lines = string.split(code, '\n')

	local currentfile
	local currentluainc
	local newlines = table()
--newlines:insert('/* incfiles: '..tolua(incfiles)..' */')
	for i,l in ipairs(lines) do
		-- skip the first BEGIN, cuz this is the BEGIN for the include we are currently generating.
		-- dont wanna swap out the whole thing
		if not currentfile then
			local beginfile = l:match'^/%* %+* BEGIN (.*) %*/$'
			if beginfile then
				local search = self.mapFromIncludeToSearchFile[beginfile]
				if search then
--newlines:insert('/* search: '..tostring(search)..' */')
--newlines:insert('/* ... checking incfiles: '..tolua(incfiles)..' */')
					-- if beginfile is one of the manually-included files then don't replace it here.
					if incfiles:find(nil, function(o)
						-- TODO if one is user then dont search for the other in sys, idk which way tho
						return search:sub(2,-2) == o:sub(2,-2)
					end) then
--newlines:insert('/* ... is already in the generate.lua args */')
					else
						-- if it's found in includeList then ...
						local _, inc = includeList:find(nil, function(o)
							-- if we're including a system file then it could be <> or ""
							if search:sub(1,1) == '"' then
								return o.inc:sub(2,-2) == search:sub(2,-2)
							else
								return o.inc == search
							end
						end)
						if not inc then
--newlines:insert("/* didn't find */")
						else
--newlines:insert('/*  ... found: '..inc.inc..' */')
							currentfile = beginfile
							currentluainc = inc.out:match'^(.*)%.lua$':gsub('/', '.')
						end
					end
				end
			end
			newlines:insert(l)
		else
			-- find the end
			local endfile = l:match'^/%* %+* END   (.*) %*/$'
			if endfile and endfile == currentfile then
				-- hmm dilemma here
				-- currentluainc says where to write the file, which is in $os/$path or $os/$arch/$path or just $path depending on the level of overriding ...
				-- but the ffi.req *here* needs to just be $path
				-- but no promises of what the name scheme will be
				-- (TODO unless I include this info in the include-list.lua ... .specificdir or whatever...)
				-- so for now i'll just match
				currentluainc = currentluainc:match('^'..string.patescape(ffi.os)..'%.(.*)$') or currentluainc
				currentluainc = currentluainc:match('^'..string.patescape(ffi.arch)..'%.(.*)$') or currentluainc
				newlines:insert("]] require 'ffi.req' '"..currentluainc.."' ffi.cdef[[")
				-- clear state
				currentfile = nil
				currentluainc = nil
				newlines:insert(l)
			end
		end
	end

	-- [[
	-- split off all {'s into newlines?
	lines = newlines
	newlines = table()
	for _,l in ipairs(lines) do
		if l:match'^/%*.*%*/$' then
			newlines:insert(l)
		else
			l = string.trim(l)
			local i = 1
			i = l:find('{', i)
			if not i then
				newlines:insert(l)
			else
				local j = l:find('}', i+1)
				if j then
					newlines:insert(l)
				else
					newlines:insert(l:sub(1,i))
					l = string.trim(l:sub(i+1))
					--i = l:find('{', i+1)
					if l ~= '' then
						newlines:insert(l)
					end
				end
			end
		end
	end
	-- add the tab
	lines = newlines
	newlines = table()
	local intab
	for _,l in ipairs(lines) do
		if l:match'^/%*.*%*/$' then
			newlines:insert(l)
		else
			if l:sub(1,1) == '}' then intab = false end
			newlines:insert(intab and '\t'..l or l)
			if l:sub(-1) == '{' then intab = true end
		end
	end
	--]]

	return newlines:concat'\n'
end


--]===============] end the code for injecting require()'s to previously-generated luajit files


local preproc = ThisPreproc()

--[[
args:
	-I<incdir> = add include dir
	-silent <inc> = include it, add it to the state, but don't add it to the output
		useful for system files that you don't want mixed in there
--]]
local args = table{...}
local verbose
for i=#args,1,-1 do	-- TOOD handle *all* args here and just use later what you read
	if args[i] == '-V' then
		table.remove(args,i)
		verbose = true
	end
end

-- include but don't output these
local silentfiles = table()
-- don't even include these
local skipfiles = table()

if ffi.os == 'Windows' then
	-- I guess pick these to match the compiler used to build luajit
	preproc[[
//#define __STDC_VERSION__	201710L	// c++17
//#define __STDCPP_THREADS__	0
#define _MSC_VER	1929
#define _MSC_FULL_VER	192930038
#define _MSVC_LANG	201402
#define _MSC_BUILD	1

// choose which apply:
#define _M_AMD64	100
//#define _M_ARM	7
//#define _M_ARM_ARMV7VE	1
//#define _M_ARM64	1
//#define _M_IX86	600
#define _M_X64	100

#define _WIN32	1
#define _WIN64	1

// used in the following to prevent inline functions ...
//	ucrt/corecrt_stdio_config.h
//	ucrt/corecrt_wstdio.h
//	ucrt/stdio.h
//	ucrt/corecrt_wconio.h
//	ucrt/conio.h
#define _NO_CRT_STDIO_INLINE 1

// This one is linked to inline functions (and other stuff maybe?)
// in a few more files...
//	ucrt/corecrt.h
//	ucrt/corecrt_io.h
//	ucrt/corecrt_math.h
//	ucrt/corecrt_startup.h
//	ucrt/corecrt_stdio_config.h
//	ucrt/corecrt_wprocess.h
//	ucrt/corecrt_wstdio.h
//	ucrt/corecrt_wstdlib.h
//	ucrt/direct.h
//	ucrt/dos.h
//	ucrt/errno.h
//	ucrt/fenv.h
//	ucrt/locale.h
//	ucrt/mbctype.h
//	ucrt/mbstring.h
//	ucrt/process.h
//	ucrt/stddef.h
//	ucrt/stdio.h
//	ucrt/stdlib.h
//	ucrt/wchar.h
// For now I'm only going to rebuild stdio.h and its dependencies with this set to 0
// maybe it'll break other headers? idk?
//#define _CRT_FUNCTIONS_REQUIRED 0
// hmm, nope, this gets rid of all the stdio stuff

// hmm this is used in vcruntime_string.h
// but it's defined in corecrt.h
// and vcruntime_string.h doesn't include corecrt.h .......
#define _CONST_RETURN const

// <vcruntime.h> has these: (I'm skipping it for now)
#define _VCRTIMP
#define _CRT_BEGIN_C_HEADER
#define _CRT_END_C_HEADER
#define _CRT_SECURE_NO_WARNINGS
#define _CRT_INSECURE_DEPRECATE(Replacement)
#define _CRT_INSECURE_DEPRECATE_MEMORY(Replacement)
#define _HAS_NODISCARD 0
#define _NODISCARD
#define __CLRCALL_PURE_OR_CDECL __cdecl
#define __CRTDECL __CLRCALL_PURE_OR_CDECL
#define _CRT_DEPRECATE_TEXT(_Text)
#define _VCRT_ALIGN(x) __declspec(align(x))

// used by stdint.h to produce some macros (which are all using non-standard MS-specific suffixes so my preproc comments them out anyways)
// these suffixes also appearn in limits.h
// not sure where else _VCRT_COMPILER_PREPROCESSOR appears tho
#define _VCRT_COMPILER_PREPROCESSOR 1

// in corecrt.h but can be overridden
// hopefully this will help:
//#define _CRT_FUNCTIONS_REQUIRED 0

// needed for stdint.h ... ?
//#define _VCRT_COMPILER_PREPROCESSOR 1

// correct me if I'm wrong but this macro says no inlines?
//#define __midl
// hmm, nope, it just disabled everything
// this one seems to lose some inlines:
#define __STDC_WANT_SECURE_LIB__ 0
// how about this one?
//#define RC_INVOKED
// ...sort of but in corecrt.h if you do set it then you have to set these as well:
// too much of a mess ...

// annoying macro.  needed at all?
#define __declspec(x)
]]

	-- I'm sure there's a proper way to query this ...
	local MSVCDir = [[C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.43.34808]]

	-- [=[ <sal.h> has these:  (included by <vcruntime.h>)
	for l in io.lines(MSVCDir..[[\include\sal.h]]) do
		local rest = l:match'^#define%s+(.*)$'
		if rest then
			local k, params, paramdef = rest:match'^(%S+)%(([^)]*)%)%s*(.-)$'
			if k then
				preproc('#define '..k..'('..params..')')
			else
				local k, v = rest:match'^(%S+)%s+(.-)$'
				if k then
					preproc('#define '..k)
				end
			end
		end
	end
	--]=]

	skipfiles:insert'<sal.h>'
	skipfiles:insert'<vcruntime.h>'
	--skipfiles:insert'<vcruntime_string.h>'	-- has memcpy ... wonder why did I remove this?
	--skipfiles:insert'<corecrt_memcpy_s.h>'	-- contains inline functions

	-- how to know where these are?
	preproc:addIncludeDirs({
		-- what's in my VS 2022 Project -> VC++ Directories -> General -> Include Directories
		MSVCDir..[[\include]],
		MSVCDir..[[\atlmfc\include]],
		[[C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\VS\include]],
		[[C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\ucrt]],
		[[C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\um]],
		[[C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\shared]],
		[[C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\winrt]],
		[[C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\cppwinrt]],
		[[C:\Program Files (x86)\Windows Kits\NETFXSDK\4.8\Include\um]],
	}, true)
else	-- assume everything else uses gcc
	assert(os.execute'gcc --version > /dev/null 2>&1', "failed to find gcc")	-- make sure we have gcc
	preproc(io.readproc'gcc -dM -E - < /dev/null 2>&1')

	local results = io.readproc'gcc -E -v - < /dev/null 2>&1'
	if verbose then
		print('results')
		print(results)
	end
	assert(results:match'include')
	assert(results:match('#include'))	-- why doesn't this match?
	assert(results:match'#include "%.%.%." search starts here:')
	local userSearchStr, sysSearchStr = results:match'#include "%.%.%." search starts here:(.-)#include <%.%.%.> search starts here:(.-)End of search list%.'
	assert(userSearchStr)
	if verbose then
		print('userSearchStr')
		print(userSearchStr)
		print('sysSearchStr')
		print(sysSearchStr)
	end
	local userSearchDirs = string.split(string.trim(userSearchStr), '\n'):mapi(string.trim)
	local sysSearchDirs = string.split(string.trim(sysSearchStr), '\n'):mapi(string.trim)
	if verbose then
		print('userSearchDirs')
		print(tolua(userSearchDirs))
		print('sysSearchDirs')
		print(tolua(sysSearchDirs))
	end
	preproc:addIncludeDirs(userSearchDirs, false)
	preproc:addIncludeDirs(sysSearchDirs, true)

	-- how to handle gcc extension macros?
	preproc[[
#define __has_feature(x)		0
#define __building_module(x)	0
#define __has_extension(x)		0
#define __has_attribute(x)		0
#define __has_cpp_attribute(x)	0
#define __has_c_attribute(x)	0
#define __has_builtin(x)		0
#define __has_include(x)		0
#define __has_warning(x)		0
#define __asm__(x)
#define __has_unique_object_representations(x) 0
#define _GLIBCXX_HAS_BUILTIN(x)	0
#define _Static_assert(a,b)		// this is in <sys/cdefs.h> ... why isn't it working in <SDL2/SDL.h> ?
]]
end


-- where I keep my glext.h and khr/khrplatform.h
-- TODO move this into gl.sh?
preproc:addIncludeDir(os.home()..'/include', ffi.os == 'Windows')

-- cwd? no, this just risks the generated file geeting included mid-generation.
-- but for testing I enable it ... with -I.
--preproc:addIncludeDir('.', false)

do
	local i = 1
	while i <= #args do
		local f = args[i]
		if f:sub(1,2) == '-I' then
			-- how to tell sys or not?
			preproc:addIncludeDir(f:sub(3), true)
			args:remove(i)
		elseif f:sub(1,2) == '-D' then
			local kv = f:sub(3)
			local k,v = kv:match'^([^=]*)=(.-)$'
			if not k then
				k, v = kv, '1'
			end
			preproc:setMacros{[k]=v}
			args:remove(i)
		elseif f == "-silent" then
			args:remove(i)
			silentfiles:insert(args:remove(i))
		elseif f == "-skip" then
			args:remove(i)
			skipfiles:insert(args:remove(i))
		elseif f == "-enumGenUnderscoreMacros" then
			args:remove(i)
			-- don't ignore underscore enums
			-- needed by complex.h since there are some _ enums its post-processing depends on
			preproc.enumGenUnderscoreMacros = true
		else
			i = i + 1
		end
	end
end
incfiles = args	-- whatever is left is include files

for _,rest in ipairs(skipfiles) do
	-- TODO this code is also in preproc.lua in #include filename resolution ...
	local sys = true
	local fn = rest:match'^<(.*)>$'
	if not fn then
		sys = false
		fn = rest:match'^"(.*)"$'
	end
	if not fn then
		error("skip couldn't find include file: "..rest)
	end
	local search = fn
	fn = preproc:searchForInclude(fn, sys)
	if not fn then
		error("skip: couldn't find "..(sys and "system" or "user").." include file "..search..'\n')
	end

io.stderr:write('skipping ', fn,'\n')
	-- treat it like we do #pragma once files
	preproc.alreadyIncludedFiles[fn] = true
end
for _,fn in ipairs(silentfiles) do
	preproc("#include "..fn)
end
local code = preproc(incfiles:mapi(function(fn)
	return '#include '..fn
end):concat'\n'..'\n')

print(code)

--print('macros: '..tolua(preproc.macros)..'\n')


--io.stderr:write('macros: '..tolua(preproc.macros)..'\n')


-- see if there's any errors here
-- TODO There will almost always be errors if you used -silent, so how about in that case automatically include the luajit of the skipped files?
--local result = xpcall(function()
--	ffi.cdef(code)
--end, function(err)
--	io.stderr:write('macros: '..tolua(preproc.macros)..'\n')
--	io.stderr:write(err..'\n'..debug.traceback())
--end)
--os.exit(result and 0 or 1)

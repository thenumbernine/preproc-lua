#!/usr/bin/env lua

local file = require 'ext.file'

--[[ this holds the stuff thats working already
-- but dont use it unless you want to regen everything
-- but it's a separate file for the sake of generate.lua looking to see what to replace with require()'s
local includeList = require 'include-list'
--]]
-- [[ here's my manual list until then

local string = require 'ext.string'

local function remove_GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION(code)
	return (code:gsub('enum { __GLIBC_INTERNAL_STARTING_HEADER_IMPLEMENTATION = 1 };\n', ''))
end

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

local function removeWarnings(code)
	return code:gsub('warning:[^\n]*\n', '')
end

local function commentOutLine(code, line)
	code = code:gsub(
		string.patescape(line),
		'/* manually commented out: '..line..' */')
	return code
end



local includeList = {
--[=[
	-- these all have some inlined enum errors:
	
	-- depends on limits.h
	{inc='dirent.h',		out='c/dirent.lua'},
	
	-- depends: sched.h time.h
	{inc='pthread.h',		out='c/pthread.lua'},

	{inc='sys/param.h', out='c/sys/param.lua', final=function(code)
		-- warning for redefining LLONG_MIN or something
		code = removeWarnings(code)
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
		code = remove_need_macro(code, 'NULL')
		return code
	end}

	{inc='sys/time.h',		out='c/sys/time.lua', final=function(code)
		code = replace_bits_types_builtin(code, 'suseconds_t')
		return code
	end},


	-- depends on bits/libc-header-start
	-- '<identifier>' expected near '_Complex' at line 2
	-- has to do with enum/define'ing the builtin word _Complex
	{inc='complex.h',		out='c/complex.lua'},
	
	-- uses a vararg macro which I don't support yet
	{inc='sys/sysinfo.h',		out='c/sys/sysinfo.lua'},


	-- "libpng requires a signed 16-bit type"
	{inc='png.h', out='png.lua', final=function(code)
		-- warning for redefining LLONG_MIN or something
		code = removeWarnings(code)
		code = [[
-- png 1.6.37 + zlib 1.2.8
]] .. code .. [[
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

--]=]
--[[ todo
	
	cblas.sh
	cimgui.sh
	ffi.sh
	fitsio.sh
	gif.sh
	hdf5.sh
	jpeg.sh
	lapacke.sh
	lapack.sh
	lua.sh
	netcdf.sh
	OpenCL.sh
	OpenGL.sh
	sdl.sh
	tiff.sh
--]]

}
--]]

local function exec(cmd)
	print('>'..cmd)
	return os.execute(cmd)
end

local outdir = 'results'
for _,inc in ipairs(includeList) do
	local outpath = outdir..'/'..inc.out
	local dir,outfn = file(outpath):getdir()
	file(dir):mkdir(true)
	file(outpath):write[=[
local ffi = require 'ffi'
ffi.cdef[[
]=]
	print(exec('luajit generate.lua "<'..inc.inc..'>" >> "'..outpath..'"'))
	file(outpath):append[=[
]]
]=]
	-- if there's a final-pass on the code then do it
	if inc.final then
		assert(file(outpath):write(
			assert(inc.final(
				assert(file(outpath):read())
			), "expected final() to return a string")
		))
	end

	-- verify ...
	-- can't use -lext because that will load ffi/c stuff which could cause clashes in cdefs
	print(exec([[luajit -e "assert(load(require 'ext.io'.readfile']]..outpath..[['))()"]]))

	break
end

#!/usr/bin/env lua

local file = require 'ext.file'

--[[ this holds the stuff thats working already
-- but dont use it unless you want to regen everything
-- but it's a separate file for the sake of generate.lua looking to see what to replace with require()'s
local includeList = require 'include-list'
--]]
-- [[ here's my manual list until then
local includeList = {
--[[
	-- "never include this file directly"
	{inc='bits/libc-header-start.h',	out='c/bits/libc-header-start.lua'},
	{inc='bits/setjmp.h',	out='c/bits/setjmp.lua'},
--]]
--[[ todo
	cblas.sh
	cimgui.sh
	complex.sh
	dirent.sh
	errno.sh
	ffi.sh
	fitsio.sh
	gif.sh
	hdf5.sh
	jpeg.sh
	lapacke.sh
	lapack.sh
	limits.sh
	lua.sh
	netcdf.sh
	OpenCL.sh
	OpenGL.sh
	png.sh
	pthread.sh
	sched.sh
	sdl.sh
	setjmp.sh
	stdarg.sh
	stddef.sh
	stdint.sh
	stdio.sh
	stdlib.sh
	string.sh
	sys_ioctl.sh
	sys_param.sh
	sys_select.sh
	sys_stat.sh
	sys_sysinfo.sh
	sys_termios.sh
	sys_time.sh
	sys_types.sh
	tiff.sh
	time.sh
	unistd.sh
	zlib.sh
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

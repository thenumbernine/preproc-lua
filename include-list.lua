-- mapping from c includes to luajit ffi/ includes
-- this is used for automated generation
-- this is also used during generation for swapping out #includes with require()'s of already-generated files
return {
	{inc='features.h',		out='c/features.lua'},
	{inc='bits/endian.h',	out='c/bits/endian.lua'},
	{inc='bits/types/locale_t.h',	out='c/bits/types/locale_t.lua'},
	{inc='bits/types/__sigset_t.h',	out='c/bits/types/__sigset_t.lua'},
	
	-- depends on features.h
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

	-- depends on bits/types.h
	{inc='bits/stdint-intn.h',	out='c/bits/stdint-intn.lua'},
	{inc='bits/types/clockid_t.h',	out='c/bits/types/clockid_t.lua'},
	{inc='bits/types/clock_t.h',	out='c/bits/types/clock_t.lua'},
	{inc='bits/types/struct_timeval.h',	out='c/bits/types/struct_timeval.lua'},
	{inc='bits/types/timer_t.h',	out='c/bits/types/timer_t.lua'},
	{inc='bits/types/time_t.h',	out='c/bits/types/time_t.lua'},

	-- depends on bits/types.h bits/endian.h
	{inc='bits/types/struct_timespec.h',	out='c/bits/types/struct_timespec.lua'},
}

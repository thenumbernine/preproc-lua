#!/usr/bin/env sh
# pkg-config is for adding -I to generate.lua's search paths
#
# Everything together:
#./generate.lua `pkg-config --cflags lua` "<lua.h>" > lua.h
#
# Omitting system include files:
./generate.lua `pkg-config --cflags lua`\
	"<lua.h>" > lua.h
#	-skip "<stdarg.h>" \
#	-skip "<stddef.h>" \
#	-skip "<stdint.h>" \
# ...after -skip "<stddef.h>" should be -skip "<limits.h>", but if I insert this to be omitted from output then lua.h preprocessing gets an error.
# Maybe my include search path order is reversed or something?

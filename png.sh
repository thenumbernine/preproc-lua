#!/usr/bin/env sh
# -skip "<limits.h>" causes "libpng requires 8-bit bytes"
luajit generate.lua \
	"<png.h>" > png.h
#	-skip "<stdio.h>" \
#	-skip "<setjmp.h>" \
#	-skip "<time.h>" \

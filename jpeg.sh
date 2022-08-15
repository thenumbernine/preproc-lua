#!/usr/bin/env sh
# don't forget to require ffi.c.stdio before ffi.jpeg
luajit generate.lua\
	"<jpeglib.h>" > jpeg.h
#	-skip "<stdio.h>"\

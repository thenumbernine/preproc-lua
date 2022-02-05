#!/usr/bin/env sh
# don't forget to require ffi.c.stdio before ffi.jpeg
luajit generate.lua\
	-skip "<stdio.h>"\
	"<jpeglib.h>" > jpeg.h

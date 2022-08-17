#!/usr/bin/env sh
# don't forget to require ffi.c.stdio before ffi.jpeg
# for libjpeg-turbo
# linux is using 2.0.3
# windows is using 2.0.4 just because 2.0.3 and cmake is breaking for msvc
luajit generate.lua "<jpeglib.h>" > jpeg.h

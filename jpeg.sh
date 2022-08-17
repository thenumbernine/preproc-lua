#!/usr/bin/env sh
# don't forget to require ffi.c.stdio before ffi.jpeg
# apt install libjpeg-turbo-dev
# linux is using 2.1.2 which generates no different than 2.0.3
#  based on apt package libturbojpeg0-dev
# windows is using 2.0.4 just because 2.0.3 and cmake is breaking for msvc
luajit generate.lua "<jpeglib.h>" > jpeg.h

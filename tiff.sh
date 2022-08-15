#!/usr/bin/env sh
# can't use tiff.h or it will get included since tiffio.h includes "tiff.h" with quotes, whose search path includes cwd .
luajit generate.lua `pkg-config --cflags libtiff-4` "<tiffio.h>" > tiffio.h

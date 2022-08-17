#!/usr/bin/env sh
# apt install libtiff-dev
luajit generate.lua `pkg-config --cflags libtiff-4` "<tiffio.h>" > tiff.h

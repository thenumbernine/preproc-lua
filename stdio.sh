#!/usr/bin/env sh
# used by jpeg.sh and hdf5.sh
# TODO maybe generate-as-you-go .h => .lua, complete with replacing #include => require()'s ?
luajit generate.lua "<stdio.h>" > stdio.h
#  -skip "<features.h>" -skip "<stddef.h>"

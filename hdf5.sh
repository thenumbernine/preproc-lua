#!/usr/bin/env sh
#I put this after sys/types.h and it lagged forever
#-skip "<unistd.h>" 
# add -DH5_SIZEOF_SSIZE_T=0
#-skip "<features.h>" -skip "<sys/types.h>" -skip "<limits.h>" -skip "<stdarg.h>" -skip "<stddef.h>" -skip "<stdlib.h>" -skip "<stdint.h>" -skip "<inttypes.h>" -skip "<stdio.h>" 
luajit generate.lua `pkg-config --cflags-only-I hdf5` "<hdf5.h>" > hdf5.h

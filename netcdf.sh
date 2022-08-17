#!/usr/bin/env sh
#-skip "<stddef.h>" 
luajit generate.lua `pkg-config --cflags netcdf` "<netcdf.h>" > netcdf.h

#!/usr/bin/env sh
luajit generate.lua -skip "<stddef.h>" `pkg-config --cflags netcdf` "<netcdf.h>" > netcdf.h

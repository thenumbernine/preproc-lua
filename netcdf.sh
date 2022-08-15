#!/usr/bin/env sh
luajit generate.lua -skip "<stddef.h>" `pkg-config --cflags-only-I netcdf` "<netcdf.h>" > netcdf.h

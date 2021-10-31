#!/usr/bin/env sh
luajit generate.lua `pkg-config --cflags-only-I netcdf` "<netcdf.h>" > netcdf.h

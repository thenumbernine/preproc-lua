#!/usr/bin/env sh
# apt install libnetcdf-dev
luajit generate.lua `pkg-config --cflags netcdf` "<netcdf.h>" > netcdf.h

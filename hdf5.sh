#!/usr/bin/env sh
# apt install libhdf5-dev
luajit generate.lua `pkg-config --cflags hdf5` "<hdf5.h>" > hdf5.h

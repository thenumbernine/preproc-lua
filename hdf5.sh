#!/usr/bin/env sh
luajit generate.lua `pkg-config --cflags hdf5` "<hdf5.h>" > hdf5.h

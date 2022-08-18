#!/usr/bin/env sh
# apt install libffi-dev
luajit generate.lua "<ffi.h>" > ffi.h

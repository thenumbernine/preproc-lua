#!/usr/bin/env sh
# don't forget to require ffi.c.time before ffi.c.pthread
luajit generate.lua "<pthread.h>" > pthread.h
# -skip "<stddef.h>" 
# -skip "<time.h>" 

#!/usr/bin/env sh
# don't forget to require ffi.c.time before ffi.c.pthread
luajit generate.lua -skip "<time.h>" "<pthread.h>" > pthread.h

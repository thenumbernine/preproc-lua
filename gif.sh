#!/usr/bin/env sh
luajit generate.lua -skip "<stddef.h>" "<gif_lib.h>" > gif.h

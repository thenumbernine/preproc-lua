#!/usr/bin/env sh
luajit generate.lua `pkg-config --cflags sdl2` "<SDL2/SDL.h>" > sdl.h

#!/usr/bin/env sh
luajit generate.lua -I../../other/cimgui -DCIMGUI_DEFINE_ENUMS_AND_STRUCTS "\"cimgui.h\"" > cimgui.h

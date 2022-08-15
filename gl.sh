#!/usr/bin/env sh
luajit generate.lua "<GL/gl.h>" -DGL_GLEXT_PROTOTYPES  "<GL/glext.h>" > gl.h

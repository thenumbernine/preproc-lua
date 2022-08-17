#!/usr/bin/env sh
luajit generate.lua "<GL/gl.h>" -DGL_GLEXT_PROTOTYPES  "<GL/glext.h>" > OpenGL.h
# for Windows I've got my glext.h outside the system paths, so you have to add that to the system path location.

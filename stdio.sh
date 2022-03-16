#!/usr/bin/env sh
# used by jpeg.sh and hdf5.sh
# TODO maybe generate-as-you-go .h => .lua, complete with replacing #include => require()'s ?
# hmm ... this leaves __REDIRECT macros unexpanded ... why?
luajit generate.lua "<stdio.h>" > stdio.h

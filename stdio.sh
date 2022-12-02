#!/usr/bin/env sh
# used by jpeg.sh and hdf5.sh
#  this needs to be modified after-the-fact: first it defines extern FILE* stdin,stdout,stderr, 
#  then it `#define stdin stdin` which somehow in my code generates an 'enum { stdin = 0}' (why?)
luajit generate.lua "<stdio.h>" > stdio.h

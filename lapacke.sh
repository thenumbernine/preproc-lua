#!/usr/bin/env sh
luajit generate.lua "<lapacke.h>" > lapacke.h "$@"

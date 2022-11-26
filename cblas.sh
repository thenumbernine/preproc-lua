#!/usr/bin/env sh
# library? libopenblas
# header? cblas.h
luajit generate.lua "<cblas.h>" > cblas.h

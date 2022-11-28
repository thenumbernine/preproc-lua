#!/usr/bin/env sh
# used by pthread.sh and lapack or cblas
luajit generate.lua "<sched.h>" > sched.h

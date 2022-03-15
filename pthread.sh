#!/usr/bin/env sh
luajit generate.lua -skip "<time.h>" "<pthread.h>" > pthread.h

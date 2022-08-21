#!/usr/bin/env sh
luajit generate.lua \
	-I../../cpp/ImGuiCommon/include \
	-DCIMGUI_DEFINE_ENUMS_AND_STRUCTS \
	"\"cimgui.h\"" \
	"\"imgui_impl_sdl.h\"" \
	"\"imgui_impl_opengl2.h\"" \
	> cimgui.h

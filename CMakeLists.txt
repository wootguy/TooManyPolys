cmake_minimum_required(VERSION 3.6)

project(TooManyPolys)

set(SOURCE_FILES
	src/main.h src/main.cpp
	src/PluginHelpAnnouncements.h src/PluginHelpAnnouncements.cpp
	src/PlayerModelPrecache.h src/PlayerModelPrecache.cpp
	src/GhostReplace.h src/GhostReplace.cpp
)

add_library(${PROJECT_NAME} SHARED)
add_subdirectory(mmlib)
mmlib_default_setup()
#pragma once
#include "mmlib.h"

void addPlayerModel(edict_t* plr);

void precachePlayerModels();

void loadPrecachedModels();

bool playerModelFileExists(std::string path);
#!/bin/sh
# Builds the desktop test harness for the slicing engine (Linux/macOS): ./build_cli.sh -> ./a1cli
set -e
cd "$(dirname "$0")"
SRC=$(ls Engine/src/*.cpp | grep -v '/net.cpp$')
c++ -O2 -std=c++17 -Wall -Wno-sign-compare -IEngine/third_party -IEngine/src -IEngine/include \
  tools/a1cli.cpp $SRC Engine/third_party/clipper2/*.cpp -lz -o a1cli

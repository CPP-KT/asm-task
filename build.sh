#!/bin/bash
set -ou pipefail

mkdir -p build
cd build || exit
cmake -G "Unix Makefiles" ..
make
cd ..

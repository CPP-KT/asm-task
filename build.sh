#!/bin/bash
set -ou pipefail

mkdir -p build
cd build || exit
cmake ..
make
cd ..

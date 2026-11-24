#!/bin/bash
set -e
cd "$(dirname "$0")/.."
cd Backend
clang++ -std=c++17 -Wall -Wextra grossify_backend.cpp -lsqlite3 -o grossify_backend
exec ./grossify_backend

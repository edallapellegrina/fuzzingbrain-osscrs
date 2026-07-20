#!/bin/bash -eu
cd /src/cjson

# Compile cJSON.c as a C file
$CC $CFLAGS -I. -c cJSON.c -o cJSON.o

# Compile and link the fuzz harness with cJSON.o
$CC $CFLAGS -I. tests/fuzz/fuzz_setvaluestring.c cJSON.o $LIB_FUZZING_ENGINE -o $OUT/fuzz_target
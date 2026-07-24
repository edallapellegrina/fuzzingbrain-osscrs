#!/bin/bash -eu

cd $SRC/vuln-test-repo

$CC $CFLAGS -I src -c src/vuln_lib.c -o vuln_lib.o

$CXX $CXXFLAGS -I src src/fuzz_target.cc vuln_lib.o $LIB_FUZZING_ENGINE -o $OUT/fuzz_target

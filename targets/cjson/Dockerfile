FROM gcr.io/oss-fuzz-base/base-builder
RUN git clone https://github.com/eliadallapellegrina/cjson-fuzzingbrain-test.git /src/cjson && cd /src/cjson && git checkout 55d9d6c1d681190ef40f417acb600ac7f5e2c524
WORKDIR /src/cjson
COPY build.sh $SRC/
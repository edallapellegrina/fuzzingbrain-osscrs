FROM gcr.io/oss-fuzz-base/base-builder

RUN mkdir -p $SRC/vuln-test-repo
COPY src $SRC/vuln-test-repo/src

COPY build.sh $SRC/
WORKDIR $SRC/vuln-test-repo

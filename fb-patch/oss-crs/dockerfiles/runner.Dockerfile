# Latest FuzzingBrain image
FROM ghcr.io/o2lab/fuzzingbrain@sha256:6da1d1d417c1c02d3e72a8f0dc69bcea535b74a7c7b5351fed667d8e11b71431

# libCRS
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh

# LLM routing patch
COPY sitecustomize.py /usr/lib/python3.10/sitecustomize.py

# Wrapper script
COPY scripts/fb_wrapper.sh /usr/local/bin/fb_wrapper.sh
RUN chmod +x /usr/local/bin/fb_wrapper.sh

# Override the image's entrypoint with the wrapper
ENTRYPOINT ["/usr/local/bin/fb_wrapper.sh"]
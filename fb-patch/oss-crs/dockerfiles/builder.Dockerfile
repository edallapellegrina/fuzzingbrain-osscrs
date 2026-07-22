ARG target_base_image
FROM $target_base_image
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/compile_target /usr/local/bin/compile_target
RUN chmod +x /usr/local/bin/compile_target
CMD ["compile_target"]

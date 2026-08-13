ARG DEBIAN_IMAGE=debian:bookworm-slim
FROM ${DEBIAN_IMAGE}

COPY --chown=root:root snell-server /usr/local/bin/snell-server
RUN chmod 0755 /usr/local/bin/snell-server

ENTRYPOINT ["/usr/local/bin/snell-server"]
CMD ["-c", "/etc/snell-server.conf"]

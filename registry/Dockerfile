FROM registry:2.8.3

COPY config.yml /etc/docker/registry/config.yml

RUN mkdir -p /certs /var/lib/registry && \
    chmod 750 /var/lib/registry && \
    chmod 750 /certs

EXPOSE 5000

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/etc/docker/registry/config.yml"]
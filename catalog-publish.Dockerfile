FROM quay.io/operator-framework/opm:latest AS builder

COPY catalog /configs
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]

FROM quay.io/operator-framework/opm:latest

COPY --from=builder /configs /configs
COPY --from=builder /tmp/cache /tmp/cache

EXPOSE 50051
ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]

LABEL io.k8s.display-name="PTP Operator FBC Catalog"
LABEL io.k8s.description="File-Based Catalog containing all ptp-operator release versions."
LABEL maintainer="PTP Team <ptp-dev@redhat.com>"
LABEL operators.operatorframework.io.index.configs.v1=/configs

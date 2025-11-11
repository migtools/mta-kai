FROM registry.redhat.io/ubi9/go-toolset:1.23 AS builder
COPY --chown=1001:0 . /workspace

# kai_analyzer_rpc does not have a Dockerfile upstream, downstream uses this container as a builder only
# Build in 3 platforms
WORKDIR /workspace/kai_analyzer_rpc
ENV GOFLAGS=-buildvcs=false
RUN GOOS=linux go build -o mta-analyzer-rpc
RUN GOOS=darwin go build -o darwin-mta-analyzer-rpc
RUN GOOS=windows go build -o windows-mta-analyzer-rpc

FROM registry.redhat.io/ubi9:latest

COPY --from=builder /workspace/kai_analyzer_rpc/mta-analyzer-rpc /usr/local/bin
COPY --from=builder /workspace/kai_analyzer_rpc/darwin-mta-analyzer-rpc /usr/local/bin
COPY --from=builder /workspace/kai_analyzer_rpc/windows-mta-analyzer-rpc /usr/local/bin
COPY --from=builder /workspace/LICENSE /licenses/

USER 1001

ENTRYPOINT ["/usr/local/bin/mta-analyzer-rpc"]

LABEL \
        description="Migration Toolkit for Applications - Analyzer RPC" \
        io.k8s.description="Migration Toolkit for Applications - Analyzer RPC" \
        io.k8s.display-name="MTA - Analyzer RPC" \
        io.openshift.maintainer.project="MTA" \
        io.openshift.tags="migration,modernization,mta,tackle,konveyor" \
        summary="Migration Toolkit for Applications - Analyzer RPC"

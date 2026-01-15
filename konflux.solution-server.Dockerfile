#FROM registry.redhat.io/ubi9:latest AS deps
#WORKDIR /workspace/
#ADD . .
#RUN pwd && ls -la
#RUN tar -zxvf mta-solution-server-deps-20250822.tgz -C /workspace/

# Tree sitter java madness (Added for 08/14/25 deps bundle)
#RUN cd hermeto-output/deps/pip/ && tar zxvf tree-sitter-0.24.0.tar.gz

# Arrow C++ libs are a pyarrow req (Added for 08/22/25 deps bundle)
#@follow_tag(registry.redhat.io/ubi9:latest)
#FROM registry.redhat.io/ubi9:9.6-1758184894 AS arrow-builder
#COPY --chown=1001:0 $REMOTE_SOURCES $REMOTE_SOURCES_DIR
#WORKDIR $REMOTE_SOURCES_DIR/mta-arrow/app/cpp
#ADD . .
#RUN dnf --refresh -y update && dnf -y install autoconf automake gcc gcc-c++ cmake ninja-build python3.12-devel && dnf -y clean all
#RUN mkdir build-release && cd build-release \
#    && cmake .. -DARROW_CSV=ON -DARROW_JSON=ON -DARROW_PYTHON=ON \
    # Downstream needs to copy these otherwise arrow will attempt downloading
#    && cp -f ../arrow/13.0.0.tar.gz src/ \
#    && cp -f ../arrow/232389d4f1012dddec4ef84861face2d2ba85709.tar.gz src/ \
#    && cp -f ../arrow/v2.0.6.tar.gz mimalloc_ep-prefix/src/ \
#    && cp -f ../arrow/v2.7.0.tar.gz utf8proc_ep-prefix/src/ \
#    && cp -f ../arrow/2022-06-01.tar.gz re2_ep-prefix/src/ \
#    && make -j8 \
#    && make install DESTDIR=/tmp/arrow-devel
#RUN tar -czf arrow-devel.tar.gz -C /tmp/arrow-devel .
#RUN rm -rf /tmp/arrow-devel

FROM registry.redhat.io/ubi9:latest AS app
COPY --chown=1001:0 . /workspace
WORKDIR /workspace

FROM registry.redhat.io/ubi9/ubi:latest

WORKDIR /app
RUN mkdir -p /data/
ENV DB_PATH=/data/kai_solutions.db
#ADD geos/ .
#RUN pwd && ls -la
# Geos-devel is a shapely build req (Added for 08/22/25 deps bundle)
#RUN dnf -y install geos-3.13.1-1.el9.x86_64.rpm geos-devel-3.13.1-1.el9.x86_64.rpm
# Use geos-devel from RH rhel-9-for-x86_64-appstream-beta-rpms, not enabling content stream because it breaks other deps
# https://access.redhat.com/downloads/content/geos/3.13.1-1.el9/x86_64/fd431d51/package
# https://access.redhat.com/downloads/content/geos-devel/3.13.1-1.el9/x86_64/fd431d51/package
RUN dnf -y install autoconf automake cargo cmake gcc gcc-c++ git libffi-devel libpq-devel ninja-build python3.12-cryptography python3.12-devel python3.12-pip python3.12-numpy tar && dnf -y clean all

# Copy project files
RUN mkdir kai_mcp_solution_server
COPY --from=app /workspace/kai_mcp_solution_server/README.md kai_mcp_solution_server/README.md
COPY --from=app /workspace/kai_mcp_solution_server/pyproject.toml kai_mcp_solution_server/pyproject.toml
COPY --from=app /workspace/kai_mcp_solution_server/requirements.txt kai_mcp_solution_server/requirements.txt
#COPY --from=app /workspace/kai/kai_mcp_solution_server/requirements-build.txt kai_mcp_solution_server/requirements-build.txt
COPY --from=app /workspace/kai_mcp_solution_server/src/ kai_mcp_solution_server/src/
COPY --from=app /workspace/LICENSE /licenses/
#COPY --from=deps /workspace/hermeto-output/ hermeto-output/

# Tree-sitter madness continued
#RUN mkdir /usr/include/tree_sitter
#COPY --from=deps /workspace/hermeto-output/deps/pip/tree-sitter-0.24.0/tree_sitter/core/lib/src/parser.h /usr/include/tree_sitter

# Unpack Arrow C++ libs (Added for 08/22/25 deps bundle)
#COPY --from=arrow-builder $REMOTE_SOURCES_DIR/mta-arrow/app/cpp/arrow-devel.tar.gz .
#RUN tar -zxvf arrow-devel.tar.gz -C /

# Fix maturin compilation issues
#ENV MATURIN_NO_INSTALL_RUST=true
#ENV PIP_FIND_LINKS=/app/hermeto-output/deps/pip/
#ENV PIP_NO_INDEX=true

# Remove build-system section with uv stuff
#RUN sed -i -e '25,28d' kai_mcp_solution_server/pyproject.toml
RUN sed -i '/\[build-system\]/{N;N;N;d}' kai_mcp_solution_server/pyproject.toml

# Install Python deps
# MAJOR HACK: We need a tarball with Rust missing dependencies and inject them via lookaside cache, OSBS/Brew disables cargo/rust features
# Konflux might help more as we could use "permissive" Hermeto or perhaps an exception for "allow_binary: true"
# See these for details and pain:
# https://redhat-internal.slack.com/archives/C05H8H5RT2N/p1750279381703689
# https://redhat-internal.slack.com/archives/C02AX10EQJW/p1750266098678299
# https://github.com/hermetoproject/hermeto/issues/983
# https://github.com/hermetoproject/hermeto/issues/984

RUN pip3.12 install --no-cache-dir ./kai_mcp_solution_server

# Clean up deps
#RUN rm -rf hermeto-output/ && rm -rf arrow-devel.tar.gz && rm -rf geos-*

# Create a non-root user
RUN useradd -m mcp
# Set permissions for the data directory
RUN chown -R mcp:0 /data

#allow access to write logs (this is a hack)
RUN chown -R mcp:0 /app
RUN chmod g+rwX /app

USER mcp

# Default to SSE transport on port 8000
EXPOSE 8000

CMD ["sh", "-c", "python3.12 -m kai_mcp_solution_server --transport streamable-http --host 0.0.0.0 --port 8000 --mount-path=${MOUNT_PATH:-/}"]

LABEL \
        description="Migration Toolkit for Applications - Solution Server" \
        io.k8s.description="Migration Toolkit for Applications - Solution Server" \
        io.k8s.display-name="MTA - Solution Server" \
        io.openshift.maintainer.project="MTA" \
        io.openshift.tags="migration,modernization,mta,tackle,konveyor" \
        summary="Migration Toolkit for Applications - Solution Server"

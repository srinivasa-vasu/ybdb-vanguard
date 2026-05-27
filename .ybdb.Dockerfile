# ─────────────────────────────────────────────────────────────────────────────
# GitHub Codespaces / devcontainer base image for ybdb-vanguard exercises.
# ─────────────────────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/devcontainers/python:3.11

ARG YB_VERSION=2025.2.3.0
ARG YB_BUILD=149
ARG YB_BIN_PATH=/usr/local/yugabyte

# create the install directory
RUN mkdir -p $YB_BIN_PATH

# detect build architecture — maps Docker's amd64/arm64 to YugabyteDB's x86_64/aarch64
ARG TARGETARCH=amd64
RUN ARCH=$([ "${TARGETARCH}" = "arm64" ] && echo "aarch64" || echo "x86_64") \
  && curl -sSLo /tmp/yugabyte.tar.gz \
      "https://downloads.yugabyte.com/releases/${YB_VERSION}/yugabyte-${YB_VERSION}-b${YB_BUILD}-linux-${ARCH}.tar.gz" \
  && tar -xvf /tmp/yugabyte.tar.gz -C $YB_BIN_PATH --strip-components=1 \
  && chmod +x $YB_BIN_PATH/bin/* \
  && rm /tmp/yugabyte.tar.gz

# run the YugabyteDB post-install hook (sets up python venvs for backup/tools)
RUN ["/usr/local/yugabyte/bin/post_install.sh"]

# hand ownership to the devcontainer user so no sudo is needed at runtime
RUN chown -R vscode:vscode $YB_BIN_PATH

# ── runtime environment ───────────────────────────────────────────────────────
ENV PATH="$YB_BIN_PATH/bin/:$PATH"

# loopback aliases used by multi-node yugabyted clusters
ENV HOST="127.0.0.1"
ENV HOST_LB="127.0.0.1"
ENV HOST_LB2="127.0.0.2"
ENV HOST_LB3="127.0.0.3"
ENV HOST_LB4="127.0.0.4"
ENV HOST_LB5="127.0.0.5"
ENV HOST_LB6="127.0.0.6"

# port constants (scripts reference these)
ENV YSQL_SOCK="5433"
ENV YCQL_SOCK="9042"
ENV MASTER_UI="7000"
ENV TSERVER_UI="9000"
ENV META_UI="15433"
ENV YCQL_API="12000"
ENV YSQL_API="13000"

EXPOSE ${YSQL_SOCK} ${YCQL_SOCK} ${MASTER_UI} ${TSERVER_UI} ${META_UI} ${YSQL_API} ${YCQL_API}

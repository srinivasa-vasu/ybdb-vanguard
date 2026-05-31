# ─────────────────────────────────────────────────────────────────────────────
# GitHub Codespaces / devcontainer base image for ybdb-vanguard exercises.
# ─────────────────────────────────────────────────────────────────────────────

# Dependabot monitors this line for new YugabyteDB releases.
# When Dependabot opens a PR bumping this tag, also update YB_VERSION + YB_BUILD below.
# BuildKit skips unreferenced stages so this image is never pulled during a real build.
FROM yugabytedb/yugabyte:2025.2.3.0-b149 AS yb_version_pin

FROM mcr.microsoft.com/devcontainers/python:3.14

ARG YB_VERSION=2025.2.3.0
ARG YB_BUILD=149
ARG YB_BIN_PATH=/usr/local/yugabyte

# create the install directory
RUN mkdir -p $YB_BIN_PATH

# BuildKit sets TARGETARCH automatically from the build platform (amd64 or arm64).
# YugabyteDB publishes two Linux packages with different naming conventions:
#   amd64  →  yugabyte-VERSION-bBUILD-linux-x86_64.tar.gz
#   arm64  →  yugabyte-VERSION-bBUILD-el8-aarch64.tar.gz
ARG TARGETARCH
RUN if [ "${TARGETARCH}" = "arm64" ]; then \
      YB_PKG="el8-aarch64"; \
    else \
      YB_PKG="linux-x86_64"; \
    fi \
  && echo "TARGETARCH=${TARGETARCH} → downloading yugabyte-${YB_VERSION}-b${YB_BUILD}-${YB_PKG}.tar.gz" \
  && curl -sSLo /tmp/yugabyte.tar.gz \
      "https://software.yugabyte.com/releases/${YB_VERSION}/yugabyte-${YB_VERSION}-b${YB_BUILD}-${YB_PKG}.tar.gz" \
  && tar -xvf /tmp/yugabyte.tar.gz -C $YB_BIN_PATH --strip-components=1 \
  && chmod +x $YB_BIN_PATH/bin/* \
  && rm /tmp/yugabyte.tar.gz

# Replace fips_install.sh with a no-op before running post_install.sh.
#
# yugabyted calls post_install.sh → fips_install.sh on EVERY start, not just
# at image build time. On Apple Silicon (linux/amd64 via Rosetta), the OpenSSL
# FIPS module initialisation hits a Rosetta limitation and exits 133 (SIGTRAP),
# which makes yugabyted report "Failed running post_install.sh" and refuse to start.
#
# The FIPS 140 compliance module is not required for these development exercises.
# Replacing fips_install.sh with a no-op fixes both the build stage and runtime.
RUN printf '#!/usr/bin/env bash\necho "FIPS init skipped (not required for lab use)"\nexit 0\n' \
      > /usr/local/yugabyte/bin/fips_install.sh \
  && chmod +x /usr/local/yugabyte/bin/fips_install.sh \
  && /usr/local/yugabyte/bin/post_install.sh

# Pre-configure VS Code keybinding: Ctrl+Shift+Enter → run selected text in terminal.
# Baking this into the image means the shortcut is active the moment VS Code
# attaches — no manual setup needed by the user.
# Two locations cover different VS Code Server versions / storage layouts.
RUN mkdir -p /home/vscode/.config/Code/User \
             /home/vscode/.vscode-server/data/User \
  && printf '[{"key":"ctrl+shift+enter","mac":"cmd+shift+enter","command":"workbench.action.terminal.runSelectedText","when":"editorTextFocus"}]\n' \
     | tee /home/vscode/.config/Code/User/keybindings.json \
           /home/vscode/.vscode-server/data/User/keybindings.json \
     > /dev/null \
  && chown -R vscode:vscode /home/vscode/.config /home/vscode/.vscode-server

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

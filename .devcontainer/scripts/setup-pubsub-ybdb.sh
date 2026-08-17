#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-pubsub-ybdb.sh  --  one-time build of the CDC applier (postCreateCommand)
#
# Shared by BOTH pub/sub exercises -- init-pubsub-ybdb (one-way) and
# init-pubsub-bidir-ybdb (two-way). They run the same applier build; all that
# differs is how many lanes are started and how each is configured, which lives
# in the exercise's own application-*.yml.
#
# These exercises have no Docker services at all: the YugabyteDB clusters run
# natively via yugabyted, and each applier lane is a plain JVM process. What
# this script prepares is the applier:
#
#   1. JDK  (the applier targets Java 21; the base image ships no JDK)
#   2. Maven
#   3. the YugabyteDB Debezium source connector, installed into the local Maven
#      repository as io.debezium:debezium-yugabyte -- it is published as a
#      GitHub release asset, not to Maven Central, so the applier's pom cannot
#      resolve it without this step
#   4. a clone of the applier repository, built into a runnable fat jar
#
# Every version and coordinate comes from the environment (defined once in
# .devcontainer/init-pubsub-ybdb/override.json) -- nothing is hardcoded here.
# -----------------------------------------------------------------------------
set -euo pipefail

JDK_VERSION="${JDK_VERSION:-21}"
MAVEN_VERSION="${MAVEN_VERSION:-3.9.11}"
YBDB_CONNECTOR_VERSION="${YBDB_CONNECTOR_VERSION:-dz.2.5.2.yb.2025.2.3}"
DEBEZIUM_ARTIFACT_VERSION="${DEBEZIUM_ARTIFACT_VERSION:-2.5.2.Final}"
APPLIER_REPO="${APPLIER_REPO:-https://github.com/srinivasa-vasu/spring-boot-cdc-stream.git}"
APPLIER_BRANCH="${APPLIER_BRANCH:-feat/cdc-txn-apply}"
APPLIER_HOME="${APPLIER_HOME:-/home/vscode/cdc-applier}"

TOOLS_DIR="/usr/local"
STAGING="/tmp/pubsub-setup"
mkdir -p "${STAGING}"

# -- Architecture detection ---------------------------------------------------
# Devcontainers on Apple Silicon are aarch64, not x86_64. Downloading the wrong
# JDK build fails at exec time with an unhelpful loader error.
case "$(uname -m)" in
    x86_64)        _JDK_ARCH="x64" ;;
    aarch64|arm64) _JDK_ARCH="aarch64" ;;
    *) echo "ERROR: unsupported architecture: $(uname -m)"; exit 1 ;;
esac
echo "Architecture: $(uname -m)  ->  JDK build ${_JDK_ARCH}"

# -- 1. JDK -------------------------------------------------------------------
JAVA_HOME_DIR="${TOOLS_DIR}/jdk-${JDK_VERSION}"
if [ -x "${JAVA_HOME_DIR}/bin/java" ]; then
    echo "JDK already present: $("${JAVA_HOME_DIR}/bin/java" -version 2>&1 | head -1)"
else
    echo "Installing Temurin JDK ${JDK_VERSION} (${_JDK_ARCH})..."
    curl -# -L --fail -o "${STAGING}/jdk.tar.gz" \
        "https://api.adoptium.net/v3/binary/latest/${JDK_VERSION}/ga/linux/${_JDK_ARCH}/jdk/hotspot/normal/eclipse"
    sudo mkdir -p "${JAVA_HOME_DIR}"
    sudo tar xz -f "${STAGING}/jdk.tar.gz" -C "${JAVA_HOME_DIR}" --strip-components=1
    echo "  $("${JAVA_HOME_DIR}/bin/java" -version 2>&1 | head -1)"
fi

# -- 2. Maven -----------------------------------------------------------------
# Two mirrors, in order. dlcdn is the fast CDN but carries ONLY the current
# release -- every other version 404s there the moment Apache cuts a new one,
# which is not something a pinned MAVEN_VERSION can avoid. archive.apache.org
# keeps every release that was ever published, so it is the reliable fallback.
_fetch() {  # _fetch <dest> <url> [url...]
    local dest="$1"; shift
    local url
    for url in "$@"; do
        echo "  trying ${url}"
        if curl -# -L --fail -o "${dest}" "${url}"; then
            return 0
        fi
        echo "  ...not available there"
    done
    echo "ERROR: could not download ${dest##*/} from any mirror." >&2
    return 1
}

MAVEN_HOME_DIR="${TOOLS_DIR}/apache-maven-${MAVEN_VERSION}"
if [ -x "${MAVEN_HOME_DIR}/bin/mvn" ]; then
    echo "Maven already present: ${MAVEN_VERSION}"
else
    echo "Installing Apache Maven ${MAVEN_VERSION}..."
    _MVN_TGZ="apache-maven-${MAVEN_VERSION}-bin.tar.gz"
    _fetch "${STAGING}/maven.tar.gz" \
        "https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/${_MVN_TGZ}" \
        "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/${_MVN_TGZ}"
    sudo tar xz -f "${STAGING}/maven.tar.gz" -C "${TOOLS_DIR}"
fi

# Put java/mvn on PATH for this script and for every future interactive shell.
export JAVA_HOME="${JAVA_HOME_DIR}"
export PATH="${JAVA_HOME}/bin:${MAVEN_HOME_DIR}/bin:${PATH}"

_profile="/etc/profile.d/10-cdc-applier.sh"
sudo tee "${_profile}" >/dev/null <<EOF
export JAVA_HOME="${JAVA_HOME_DIR}"
export PATH="\${JAVA_HOME}/bin:${MAVEN_HOME_DIR}/bin:\${PATH}"
EOF
sudo chmod 644 "${_profile}"
# /etc/profile.d is only read by login shells; VS Code opens non-login bash.
grep -q '10-cdc-applier.sh' /home/vscode/.bashrc 2>/dev/null \
    || echo ". ${_profile}" >> /home/vscode/.bashrc

echo "Using $(java -version 2>&1 | head -1)"
echo "Using $(mvn -v 2>&1 | head -1)"

# -- 3. YugabyteDB Debezium connector -> local Maven repository ---------------
# The applier's pom declares io.debezium:debezium-yugabyte:${DEBEZIUM_ARTIFACT_VERSION}.
# That artifact only exists as a GitHub release asset, so install it by hand.
YB_JAR="yugabytedb-source-connector-${YBDB_CONNECTOR_VERSION}-jar-with-dependencies.jar"
echo "Downloading YugabyteDB source connector ${YBDB_CONNECTOR_VERSION}..."
curl -# -L --fail -o "${STAGING}/${YB_JAR}" \
    "https://github.com/yugabyte/debezium/releases/download/${YBDB_CONNECTOR_VERSION}/${YB_JAR}"
python3 -c "import sys; d=open('${STAGING}/${YB_JAR}','rb').read(4); sys.exit(0 if d[:2]==b'PK' else 1)" 2>/dev/null \
    || { echo "ERROR: downloaded file is not a valid JAR (no PK header)."; exit 1; }
echo "  OK: $(ls -lh "${STAGING}/${YB_JAR}" | awk '{print $5}') — valid JAR"

cat > "${STAGING}/debezium-yugabyte.pom" <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.debezium</groupId>
  <artifactId>debezium-yugabyte</artifactId>
  <version>${DEBEZIUM_ARTIFACT_VERSION}</version>
  <description>YugabyteDB Debezium Connector</description>
  <packaging>jar</packaging>
</project>
EOF

echo "Installing debezium-yugabyte:${DEBEZIUM_ARTIFACT_VERSION} into the local Maven repository..."
mvn -q install:install-file \
    -Dfile="${STAGING}/${YB_JAR}" \
    -DpomFile="${STAGING}/debezium-yugabyte.pom" \
    -DgroupId=io.debezium \
    -DartifactId=debezium-yugabyte \
    -Dversion="${DEBEZIUM_ARTIFACT_VERSION}" \
    -Dpackaging=jar

# -- 4. Clone and build the applier -------------------------------------------
if [ -d "${APPLIER_HOME}/.git" ]; then
    echo "Applier source already cloned — refreshing ${APPLIER_BRANCH}..."
    git -C "${APPLIER_HOME}" fetch --depth 1 origin "${APPLIER_BRANCH}"
    git -C "${APPLIER_HOME}" reset --hard FETCH_HEAD
else
    echo "Cloning ${APPLIER_REPO} (${APPLIER_BRANCH})..."
    git clone --depth 1 --branch "${APPLIER_BRANCH}" "${APPLIER_REPO}" "${APPLIER_HOME}"
fi

echo "Building the applier (this downloads the Maven dependency tree once)..."
mvn -B -f "${APPLIER_HOME}/pom.xml" -DskipTests clean package

_jar=$(ls "${APPLIER_HOME}"/target/*.jar 2>/dev/null | grep -v '\.original$' | head -1)
[ -n "${_jar}" ] || { echo "ERROR: the applier build produced no jar."; exit 1; }
echo "Applier jar: ${_jar}  ($(ls -lh "${_jar}" | awk '{print $5}'))"

rm -rf "${STAGING}"

echo ""
echo "Pub/Sub setup complete."
echo "  JDK    : ${JAVA_HOME_DIR}"
echo "  Maven  : ${MAVEN_HOME_DIR}"
echo "  Applier: ${APPLIER_HOME}  (branch ${APPLIER_BRANCH})"

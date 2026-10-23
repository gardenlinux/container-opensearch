#!/usr/bin/env bash
set -euo pipefail

# --- configuration -----------------------------------------------------------

REPO_URL="${REPO_URL:-https://github.com/opensearch-project/OpenSearch}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/gardenlinux/gardenlinux/fips:1877.22}"
WORKDIR="${WORKDIR:-./.build/opensearch-fips-build}"
IMAGE_NAME="${IMAGE_NAME:-gl-fips-opensearch}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
VERSION="${VERSION:-3.9.0}"
UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA:-4ee42a94e87f66fbf1e62a9871b1b87f91e02472}"
BUILD_IMAGE="${BUILD_IMAGE:-eclipse-temurin:25-jdk-jammy}"

# --- prerequisites -----------------------------------------------------------

check_tool() { command -v "$1" &>/dev/null || { echo "error: $1 not found" >&2; exit 1; }; }
check_tool git
check_tool docker
check_tool rsync
docker buildx version &>/dev/null || { echo "error: docker buildx not available" >&2; exit 1; }

# --- buildx driver -----------------------------------------------------------

if ! docker buildx inspect fips-builder &>/dev/null; then
    docker buildx create --name fips-builder --driver docker-container
fi
docker buildx use fips-builder

# --- clone / checkout --------------------------------------------------------

CLONE_DIR=".build/fips-port-opensearch"
if [ ! -d "${CLONE_DIR}" ]; then
    git clone "${REPO_URL}" "${CLONE_DIR}"
fi
git -C "${CLONE_DIR}" checkout "${VERSION}" 2>/dev/null || \
    git -C "${CLONE_DIR}" checkout "tags/${VERSION}" 2>/dev/null

# --- prepare build context ---------------------------------------------------

mkdir -p "${WORKDIR}"

# Copy source to build working directory (exclude git history and prior build output)
rsync -a --delete \
    --exclude='.git' \
    --exclude='build/' \
    "${CLONE_DIR}/" "${WORKDIR}/src/"

# Copy BCFKS truststore into build context
cp "${CLONE_DIR}/buildSrc/src/main/resources/opensearch-fips-truststore.bcfks" \
   "${WORKDIR}/opensearch-fips-truststore.bcfks"

# --- generate Dockerfile.fips ------------------------------------------------

cat > "${WORKDIR}/Dockerfile.fips" <<DOCKERFILE
################################################################################
# Stage 0: Build the OpenSearch FIPS distribution using Gradle
################################################################################
FROM --platform=\$BUILDPLATFORM ${BUILD_IMAGE} AS gradle-builder
ARG ARCH
ARG VERSION
ARG UPSTREAM_GIT_SHA

WORKDIR /build/src

# Install protoc (needed by some OpenSearch modules) and build utilities
RUN apt-get update -q && \\
    apt-get install -y --no-install-recommends unzip curl rsync && \\
    PROTOC_ARCH=\$(case "\${ARCH}" in arm64|aarch64) echo linux-aarch_64;; *) echo linux-x86_64;; esac) && \\
    curl -fsSL "https://github.com/protocolbuffers/protobuf/releases/download/v33.0/protoc-33.0-\${PROTOC_ARCH}.zip" -o /tmp/protoc.zip && \\
    unzip /tmp/protoc.zip -d /usr/local && \\
    rm /tmp/protoc.zip && \\
    rm -rf /var/lib/apt/lists/*

COPY src/ .

# Build the FIPS distribution tar (includes bc-fips JARs via -Pcrypto.standard=FIPS-140-3)
RUN --mount=type=cache,target=/root/.gradle \\
    ./gradlew \\
        :distribution:archives:linux-tar:assemble \\
        -Pcrypto.standard=FIPS-140-3 \\
        --no-build-cache \\
        -Dorg.gradle.daemon=false \\
        -Dorg.gradle.parallel=false \\
        -Dorg.gradle.jvmargs="-Xmx3g"

# Build arm64 tar when targeting arm64
RUN --mount=type=cache,target=/root/.gradle \\
    case "\${ARCH}" in \\
        arm64) \\
            ./gradlew \\
                :distribution:archives:linux-arm64-tar:assemble \\
                -Pcrypto.standard=FIPS-140-3 \\
                --no-build-cache \\
                -Dorg.gradle.daemon=false \\
                -Dorg.gradle.parallel=false \\
                -Dorg.gradle.jvmargs="-Xmx3g" ;; \\
        *) echo "skipping arm64 tar (arch=\${ARCH})" ;; \\
    esac

################################################################################
# Stage 1: Extract the tarball and apply FIPS configuration patches
################################################################################
FROM --platform=\$BUILDPLATFORM ${BUILD_IMAGE} AS extractor
ARG ARCH
ARG VERSION

RUN --mount=from=gradle-builder,source=/build/src/distribution/archives,target=/tmp/archives \\
    mkdir -p /opensearch && \\
    case "\${ARCH}" in \\
        arm64) \\
            tar -xzf /tmp/archives/linux-arm64-tar/build/distributions/opensearch-min-*-linux-arm64.tar.gz \\
                --strip-components=1 -C /opensearch ;; \\
        *) \\
            tar -xzf /tmp/archives/linux-tar/build/distributions/opensearch-min-*-linux-x64.tar.gz \\
                --strip-components=1 -C /opensearch ;; \\
    esac

# Copy the BCFKS truststore into config
COPY opensearch-fips-truststore.bcfks /opensearch/config/opensearch-fips-truststore.bcfks

# Mark as Docker distribution
RUN sed -i 's/OPENSEARCH_DISTRIBUTION_TYPE=tar/OPENSEARCH_DISTRIBUTION_TYPE=docker/' \\
    /opensearch/bin/opensearch-env

# Patch the bundled JDK's java.security to register BC FIPS providers statically
# (mirrors what opensearch's fips_java.security does, but at the JVM level so
#  "java -version" and the test suite can verify providers without runtime override)
RUN JAVA_SECURITY=\$(find /opensearch/jdk -name java.security | head -1) && \\
    sed -i \\
        -e 's|^security\.provider\.1=.*|security.provider.1=org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider C:HYBRID;ENABLE{All};|' \\
        -e 's|^security\.provider\.2=.*|security.provider.2=org.bouncycastle.jsse.provider.BouncyCastleJsseProvider fips:BCFIPS|' \\
        -e 's|^security\.provider\.3=.*|security.provider.3=SUN|' \\
        -e 's|^security\.provider\.4=.*|security.provider.4=SunJGSS|' \\
        -e '/^security\.provider\.[5-9]/d' \\
        -e '/^security\.provider\.1[0-9]/d' \\
        -e 's|^ssl\.KeyManagerFactory\.algorithm=.*|ssl.KeyManagerFactory.algorithm=PKIX|' \\
        "\${JAVA_SECURITY}"

# Append BCFKS truststore JVM options using absolute paths
# (the JVM options parser does not expand shell variables)
RUN printf '\\n-Djavax.net.ssl.trustStore=/usr/share/opensearch/config/opensearch-fips-truststore.bcfks\\n' \\
        >> /opensearch/config/jvm.options && \\
    printf '%s\\n' '-Djavax.net.ssl.trustStoreType=BCFKS' >> /opensearch/config/jvm.options && \\
    printf '%s\\n' '-Djavax.net.ssl.trustStoreProvider=BCFIPS' >> /opensearch/config/jvm.options && \\
    printf '%s\\n' '-Djavax.net.ssl.trustStorePassword=changeit' >> /opensearch/config/jvm.options

# Set up directories and permissions
RUN mkdir -p /opensearch/config/jvm.options.d /opensearch/data /opensearch/logs && \\
    chmod 0775 /opensearch/config /opensearch/config/jvm.options.d /opensearch/data /opensearch/logs && \\
    chmod 0660 /opensearch/config/opensearch.yml /opensearch/config/log4j2.properties

################################################################################
# Stage 2: Final GardenLinux FIPS image
################################################################################
FROM ${BASE_IMAGE}
ARG UPSTREAM_GIT_SHA

LABEL org.opencontainers.image.description="A FIPS-enabled OpenSearch image"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="\${UPSTREAM_GIT_SHA}"

ENV OPENSEARCH_CONTAINER=true
ENV OPENSEARCH_FIPS_MODE=true
ENV PATH=/usr/share/opensearch/bin:\$PATH

# Install runtime dependencies (gardenlinux is Debian-based; apt-get is available)
# Note: 'zip' is not in the gardenlinux 1877.22 repo; 'unzip' is sufficient for plugin installs
RUN apt-get update -q && \\
    apt-get install -y --no-install-recommends \\
        tini \\
        unzip \\
    && rm -rf /var/lib/apt/lists/*

# Create opensearch user/group (nonroot GID 1000 must be created before useradd)
RUN groupadd -g 1000 opensearch && \\
    useradd -u 1000 -g 1000 -s /sbin/nologin -d /usr/share/opensearch opensearch

COPY --from=extractor --chown=1000:0 /opensearch /usr/share/opensearch

# Copy the upstream entrypoint script
COPY --from=gradle-builder \\
    /build/src/distribution/docker/src/docker/bin/docker-entrypoint.sh \\
    /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

# Fix JDK directory permissions so java can run under a different group
RUN find /usr/share/opensearch/jdk -type d -exec chmod 0755 '{}' +

# Ensure top-level opensearch dir is group-writable
RUN chmod 0775 /usr/share/opensearch

WORKDIR /usr/share/opensearch

EXPOSE 9200 9300

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["opensearchwrapper"]
DOCKERFILE

# --- build -------------------------------------------------------------------

docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg ARCH="${ARCH}" \
    --build-arg VERSION="${VERSION}" \
    --build-arg UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA}" \
    --no-cache-filter gradle-builder \
    --no-cache-filter extractor \
    --load \
    --tag "${IMAGE_NAME}:${VERSION}-${ARCH}" \
    --file "${WORKDIR}/Dockerfile.fips" \
    "${WORKDIR}"

# --- report ------------------------------------------------------------------

echo "Built: ${IMAGE_NAME}:${VERSION}-${ARCH}"

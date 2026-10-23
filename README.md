FIPS Port: OpenSearch
=====================

## Summary

OpenSearch is an open-source, distributed search and analytics engine derived from Elasticsearch,
primarily used for log analytics, full-text search, and observability. This port produces a
FIPS-140-3-enabled container image based on GardenLinux FIPS, using the BouncyCastle FIPS JCE/JSSE
providers that are already integrated upstream.

## Triage

- Primary language: Java (Gradle build system, buildSrc/ present)
- FIPS mechanism: BouncyCastle FIPS (java-bouncycastle)
  - bc-fips 2.1.3 and bctls-fips 2.1.24 already integrated upstream
  - Build-time activation: -Pcrypto.standard=FIPS-140-3 (includes BC JARs in lib/)
  - Runtime activation: OPENSEARCH_FIPS_MODE=true env var → startup script loads fips_java.security
- Build pattern: Pattern D — Gradle builds the distribution tar inside a Docker builder stage
  (the upstream uses a Groovy SimpleTemplateEngine template rendered by Gradle, so the simplest
  approach is to invoke Gradle directly inside the builder to produce the full distribution)
- License: Apache-2.0

## Application Metadata

- Version: 3.9.0 (latest release tag; git checkout produces 3.9.0-SNAPSHOT build)
- License: Apache-2.0
- Upstream git commit SHA: 4ee42a94e87f66fbf1e62a9871b1b87f91e02472
- FIPS library: BouncyCastle FIPS (bc-fips-2.1.3.jar, bctls-fips-2.1.24.jar)
- Builder image: eclipse-temurin:25-jdk-jammy (Adoptium JDK 25.0.4.1+1, multi-arch)

## Docker Images Built

- gl-fips-opensearch:3.9.0-amd64 — 276 MB (compressed), 865 MB (uncompressed)
  Based on ghcr.io/gardenlinux/gardenlinux/fips:1877.22

## Steps Taken

### Initial script generation
- Identified Gradle as the build system via presence of buildSrc/ and build.gradle
- Identified BouncyCastle FIPS as the FIPS mechanism (bc-fips, bctls-fips in gradle/libs.versions.toml)
- Chose Pattern D: generate Dockerfile.fips heredoc with a 3-stage build:
  - Stage 0 (gradle-builder): build FIPS distribution tar inside eclipse-temurin:25-jdk-jammy
  - Stage 1 (extractor): extract tar, apply FIPS patches to JDK java.security and jvm.options
  - Stage 2 (final): copy artifacts into gardenlinux FIPS base, install tini+unzip, set up user
- Dropped from upstream: RUN dnf (no dnf in gardenlinux), ln -sf cacerts (no pki/ca-trust),
  chmod g=u /etc/passwd (OpenShift shim), find / -perm -4000 (security hardening)

### Fix 1: Wrong package — zip not available
- Symptom: E: Package 'zip' has no installation candidate
- Fix: Removed 'zip' from apt-get install; kept only 'tini' and 'unzip'

### Fix 2: Wrong Gradle task name
- Symptom: Cannot locate tasks that match ':distribution:archives:linux-tar:buildArchive'
- Root cause: Task is 'assemble', not 'buildArchive'
- Fix: Changed to :distribution:archives:linux-tar:assemble
- Also added --no-cache-filter gradle-builder to force re-run after the fix

### Fix 3: Stale BuildKit cache in extractor stage
- Symptom: Extractor stage COPY steps showed CACHED (from the failed run) and failed with "not found"
- Fix: Added --no-cache-filter extractor to the docker buildx build command

### Fix 4: Filename includes -SNAPSHOT suffix
- Symptom: opensearch-min-3.9.0-linux-x64.tar.gz not found; actual filename is
  opensearch-min-3.9.0-SNAPSHOT-linux-x64.tar.gz (the 3.9.0 tag is a snapshot)
- Root cause: Gradle uses the project's version string which includes -SNAPSHOT for this tag
- Fix: Replaced COPY --from=gradle-builder with RUN --mount=from=gradle-builder and used
  a shell glob (opensearch-min-*-linux-x64.tar.gz) to match any version string

### Fix 5: printf with -D argument
- Symptom: /bin/sh: 1: printf: Illegal option -D
- Root cause: printf '-Djavax...\n' treats '-D' as a printf flag in dash (the default sh in jammy)
- Fix: Changed to printf '%s\n' '-Djavax...' for all lines starting with -D

### BCFKS truststore and JDK provider registration
- The upstream ships opensearch-fips-truststore.bcfks in buildSrc/src/main/resources/
- Copied into build context and placed in config/ at image build time
- Four JVM options appended to jvm.options with absolute paths (JVM parser doesn't expand vars)
- Bundled JDK's jdk/conf/security/java.security patched to register BC FIPS providers at
  positions 1 and 2 (required for bare 'java -version' to show BC providers)

### Entrypoint
- Upstream docker-entrypoint.sh copied from distribution/docker/src/docker/bin/
- Script uses 'chroot --userspec=1000:0' to switch from root to uid 1000 at runtime
- tini used as init process to handle signal forwarding and zombie reaping

## Test Results

### test-image.sh output (exit 0 — all passed)
- Image available: PASS
- GardenLinux base (NAME="Garden Linux"): PASS
- FIPS-enabled variant (VARIANT_ID=container-sslfips-amd64): PASS
- BouncyCastle providers in JVM (java -XshowSettings:all -version | grep -i bouncy): PASS
  - security.provider.1=BouncyCastleFipsProvider C:HYBRID
  - security.provider.2=BouncyCastleJsseProvider fips:BCFIPS
- OCI label description: PASS
- OCI label licenses (Apache-2.0): PASS
- OCI label revision (4ee42a94e87f66fbf1e62a9871b1b87f91e02472): PASS

### k3s cluster test (k3d fips-test cluster)
- Pod: fips-port-opensearch-pod / Status: Running / Result: PASS
- Key log lines confirming FIPS operation:
  [INFO] running in FIPS-140-3 mode
  [INFO] version[3.9.0-SNAPSHOT], JVM[Eclipse Adoptium/OpenJDK 64-Bit Server VM/25.0.4.1]
  FIPS mode enabled, setting JVM options.
  Using value of KEYSTORE_PASSWORD from the environment
  [INFO] Node started (single-node discovery, HTTP on :9200, transport on :9300)
- Note: KEYSTORE_PASSWORD must be at least 14 characters (112 bits) in FIPS mode due to
  BouncyCastle FIPS PBKDF2 minimum key length requirement (FipsUnapprovedOperationError otherwise)

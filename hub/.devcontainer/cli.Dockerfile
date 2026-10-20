FROM docker:29-cli AS docker
FROM node:24-bookworm-slim

COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker /usr/local/libexec/docker

ARG NPM_CONFIG_REGISTRY=https://registry.npmjs.org/

RUN npm install --global @devcontainers/cli@0.89.0

ENTRYPOINT ["devcontainer"]

# Stage 1: Build the Next.js app
# Node 24 is the active LTS (supported until 2028-04)
FROM node:24-alpine AS builder

WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1 \
    HUSKY=0

# Install exactly what package-lock.json pins. Copying the manifests first keeps this layer cached
# until the dependencies change.
COPY package.json package-lock.json ./
RUN npm ci

# `output: 'standalone'` in next.config.ts makes the build emit .next/standalone
COPY . .
RUN npm run build

# Stage 2: Run the Next.js app with a lightweight image
FROM node:24-alpine

WORKDIR /app
# HOSTNAME must be 0.0.0.0: server.js otherwise binds to the container's hostname and Traefik cannot reach it
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

# The standalone output is a minimal server with only the dependencies it traced (no devDependencies,
# no npm). It does not include the static assets and public/, which are copied next to it.
COPY --from=builder --chown=node:node /app/.next/standalone ./
COPY --from=builder --chown=node:node /app/.next/static ./.next/static
COPY --from=builder --chown=node:node /app/public ./public

# npm, npx, corepack and yarn are not needed to run `node server.js`. Removing them drops their bundled
# dependencies (which are the only vulnerabilities Trivy reports on the base image) and a shell-reachable
# package manager from a container that may get compromised.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /opt/yarn-* /usr/local/bin/yarn /usr/local/bin/yarnpkg

# Do not run as root
USER node

EXPOSE 3000

# Start the standalone server directly (no npm process in between, so it receives SIGTERM)
CMD ["node", "server.js"]

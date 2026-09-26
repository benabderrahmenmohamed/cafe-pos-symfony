# syntax=docker/dockerfile:1.7

# ---- Build the static app ----------------------------------------------------------------------
FROM node:22-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
# Lifecycle scripts are skipped: none is needed to build (esbuild and Tailwind ship their binaries as
# optional dependencies, and msw's only copies a browser worker nothing here uses), so an install runs
# no third-party code.
RUN npm ci --ignore-scripts

# .dockerignore keeps the host's node_modules and .env out: the first would replace the Linux
# dependencies installed just above, and the second would put local values in a readable layer.
COPY . .

# Vite inlines these at build time. The default image is the credential-free memory demo; with
# VITE_BACKEND=rest it is the café, and VITE_API_BASE_URL says where the Symfony server is.
ARG VITE_BACKEND=memory
ARG VITE_API_BASE_URL=
ENV VITE_BACKEND=$VITE_BACKEND \
    VITE_API_BASE_URL=$VITE_API_BASE_URL

RUN npm run build

# ---- Serve it ----------------------------------------------------------------------------------
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runtime

COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY docker/security-headers.conf /etc/nginx/snippets/security-headers.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 8080
# --start-period so the first seconds of a starting container are not counted as failures.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

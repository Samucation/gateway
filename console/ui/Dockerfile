# --- Stage 1: build the Angular bundle -------------------------------------
FROM node:20-alpine AS build
WORKDIR /app

# Cache de deps
COPY package.json ./
RUN npm install --no-audit --no-fund --loglevel=warn

# Build
COPY tsconfig.json tsconfig.app.json angular.json proxy.conf.json ./
COPY src ./src
RUN npx ng build --configuration production

# --- Stage 2: serve com nginx + reverse proxies ----------------------------
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/sigma-ops-ui/browser /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost/health || exit 1

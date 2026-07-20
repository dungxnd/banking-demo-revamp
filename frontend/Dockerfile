FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --prefer-offline
COPY . .
RUN npm run build

FROM nginx:alpine
# Install the NGINX OTel dynamic module (ngx_otel_module.so).
#
# nginx.org publishes the module as a versioned .apk at:
#   https://nginx.org/packages/mainline/alpine/v<ALPINE>/main/<ARCH>/
# keyed to the exact Alpine + NGINX version (e.g. nginx-module-otel-1.31.2.0.1.2-r1.apk).
# The package is NOT in Alpine's own apk repos — it must be fetched from nginx.org.
#
# We add the nginx.org repo to apk's repo list, then install by package name.
# The repo key is fetched from nginx.org and trusted explicitly so the build
# does not require --allow-untrusted on every future update.
#
# libstdc++ is a runtime dependency of the module's C++ shared library.
RUN apk add --no-cache libstdc++ && \
    ALPINE_VERSION=$(cat /etc/alpine-release | cut -d. -f1-2 | sed 's/^/v/') && \
    ARCH=$(uname -m) && \
    wget -qO /etc/apk/keys/nginx_signing.rsa.pub \
        https://nginx.org/keys/nginx_signing.rsa.pub && \
    echo "https://nginx.org/packages/mainline/alpine/${ALPINE_VERSION}/main" \
        >> /etc/apk/repositories && \
    apk add --no-cache "nginx-module-otel"
COPY --from=build /app/dist /usr/share/nginx/html
# Replace the main nginx.conf so the Instana sensor can find stub_status and
# the OTel module is loaded. The agent scans /proc/<pid>/root/etc/nginx/nginx.conf
# directly — it does not follow conf.d/ includes, so both must be in this file.
COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]

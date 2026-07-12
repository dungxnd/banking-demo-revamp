FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --prefer-offline
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
# Replace the main nginx.conf so the Instana sensor can find stub_status.
# The agent scans /proc/<pid>/root/etc/nginx/nginx.conf directly — it does
# not follow conf.d/ includes, so stub_status must be in the main file.
COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]

# VendorFlow web image (Angular build served by nginx). Build from the repository root:
#   docker build -f VendorFlowWEB/Dockerfile -t vendorflow-web .
FROM node:22-alpine AS build
WORKDIR /app
COPY VendorFlowWEB/package*.json ./
RUN npm ci
COPY VendorFlowWEB/ .
RUN npx ng build --configuration production

FROM nginx:1.27-alpine
COPY VendorFlowWEB/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/VendorFlowWEB/browser /usr/share/nginx/html
EXPOSE 80

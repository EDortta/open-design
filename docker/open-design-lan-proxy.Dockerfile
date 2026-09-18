FROM nginx:1.27-alpine
COPY nginx/open-design-lan.conf /etc/nginx/conf.d/default.conf

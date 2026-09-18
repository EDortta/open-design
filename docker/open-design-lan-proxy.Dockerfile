FROM nginx:1.27-alpine

RUN cat >/etc/nginx/conf.d/default.conf <<'EOF'
server {
    listen 0.0.0.0:7456;
    server_name _;

    client_max_body_size 25m;

    location / {
        proxy_pass http://127.0.0.1:7456;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

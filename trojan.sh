#!/bin/bash
set -euo pipefail

# =========================================
# DEPLOYER - HTTPUpgrade WITH PASSWORD
# =========================================

GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
NC='\033[0m'

# VARIABLES
PROJECT_ID="$(gcloud config get-value project 2>/dev/null || echo "")"
REGION="us-central1"
RAND=$(openssl rand -hex 3)
SERVICE_NAME="rafael-${RAND}"
DOMAIN="www.google.com"
BUILD_DIR=$(mktemp -d)
PASSWORD="rafaeltv" # ITO ANG PASSWORD
UUID="15f7e8ea-7b56-45d4-93af-31f3c592fdf1"

trap 'rm -rf "$BUILD_DIR"' EXIT

# CHECK PROJECT
clear
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}✅ HTTPUpgrade WITH PASSWORD${NC}"
echo -e "${CYAN}=========================================${NC}"

[ -z "$PROJECT_ID" ] && { echo -e "${RED}Set project: gcloud config set project YOUR_ID${NC}"; exit 1; }

# ENABLE APIS
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com --quiet

# SETTINGS
echo -e "\n${CYAN}SELECT MODE:${NC}"
echo "1) Request-Based"
echo "2) Instance-Based ✅ REKOMENDADO"
read -p "Choose [1-2]: " BILL
if [ "$BILL" = "2" ]; then
  BILL_FLAGS="--no-cpu-throttling --cpu-boost"
  MEM="2Gi"
  CPU="1"
else
  BILL_FLAGS="--cpu-throttling"
  MEM="1Gi"
  CPU="1"
fi

TIMEOUT="3600"
CONCURRENCY="1000"
MIN_INST="0"
MAX_INST="2"

cd "$BUILD_DIR" || exit 1

# ✅ XRAY CONFIG - TROJAN + HTTPUpgrade (MAY PASSWORD)
cat > config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "trojan-ws",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": {"clients": [{"password": "$PASSWORD"}]},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/trojan-rafael?ed=2180"}
      }
    },
    {
      "tag": "vless-ws",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {"clients": [{"id": "$UUID"}], "decryption": "none"},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vless-rafael?ed=2180"}
      }
    },
    {
      "tag": "trojan-httpupgrade",
      "port": 11004,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": {"clients": [{"password": "$PASSWORD"}]},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]},
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "path": "/httpupgrade-rafael?ed=2180",
          "host": "$DOMAIN"
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF

# ✅ NGINX CONFIG
cat > nginx.conf <<EOF
worker_processes auto;
worker_rlimit_nofile 65535;

events { worker_connections 65535; multi_accept on; }

http {
  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 3600;
  client_max_body_size 0;

  proxy_connect_timeout 300s;
  proxy_send_timeout 3600s;
  proxy_read_timeout 3600s;
  proxy_buffering off;
  proxy_request_buffering off;

  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

  server {
    listen 8080;

    location / {
      proxy_ssl_server_name on;
      proxy_pass https://$DOMAIN;
      proxy_set_header Host $DOMAIN;
    }

    location /trojan-rafael {
      proxy_pass http://127.0.0.1:10001;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_read_timeout 3600s;
    }

    location /vless-rafael {
      proxy_pass http://127.0.0.1:10002;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_read_timeout 3600s;
    }

    # ✅ HTTPUpgrade WITH PASSWORD
    location /httpupgrade-rafael {
      proxy_pass http://127.0.0.1:11004;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_buffering off;
      proxy_read_timeout 3600s;
    }
  }
}
EOF

# ✅ ENTRYPOINT
cat > entrypoint.sh <<EOF
#!/bin/sh
set -e
/usr/local/bin/xray run -c /etc/xray/config.json &
sleep 5
exec /usr/local/openresty/bin/openresty -g 'daemon off;'
EOF
chmod +x entrypoint.sh

# ✅ DOCKERFILE
cat > Dockerfile <<EOF
FROM alpine:3.20 AS xray-bin
RUN apk add --no-cache curl unzip
WORKDIR /tmp
RUN curl -sL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip \
    && unzip xray.zip xray && chmod +x xray && mv xray /usr/local/bin/

FROM openresty/openresty:alpine
RUN apk add --no-cache ca-certificates
COPY --from=xray-bin /usr/local/bin/xray /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 8080
CMD ["/entrypoint.sh"]
EOF

# BUILD & DEPLOY
echo -e "\n${CYAN}Building image...${NC}"
gcloud builds submit --tag=gcr.io/$PROJECT_ID/$SERVICE_NAME --quiet

echo -e "\n${CYAN}Deploying...${NC}"
gcloud run deploy $SERVICE_NAME \
  --image gcr.io/$PROJECT_ID/$SERVICE_NAME \
  --platform managed \
  --region $REGION \
  --allow-unauthenticated \
  --port 8080 \
  --memory $MEM \
  --cpu $CPU \
  --concurrency $CONCURRENCY \
  --timeout $TIMEOUT \
  --min-instances $MIN_INST \
  --max-instances $MAX_INST \
  --execution-environment gen2 \
  $BILL_FLAGS \
  --quiet

# RESULT
SERVICE_URL=$(gcloud run services describe $SERVICE_NAME --region $REGION --format='value(status.url)' | sed 's|https://||')

echo -e "\n${GREEN}=========================================${NC}"
echo -e "${GREEN}✅ DEPLOYED - MAY PASSWORD NA!${NC}"
echo -e "${GREEN}=========================================${NC}"

echo -e "\n${CYAN}--- HTTPUpgrade (MAY PASSWORD) ---${NC}"
echo "Protocol: Trojan"
echo "Network: HTTPUpgrade"
echo "Address: $SERVICE_URL"
echo "Port: 443"
echo "Password: $PASSWORD"
echo "Path: /httpupgrade-rafael?ed=2180"
echo "TLS: ON"
echo "SNI: $DOMAIN"

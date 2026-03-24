#!/bin/bash

DOMAIN="$1"

if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 domain.com"
  exit 1
fi

/root/.acme.sh/acme.sh --renew -d "$DOMAIN" --force

ACME_BASE="/root/.acme.sh"
LIVE_DIR="/etc/letsencrypt/live/$DOMAIN"

if [ -d "$ACME_BASE/${DOMAIN}_ecc" ]; then
  SRC_DIR="$ACME_BASE/${DOMAIN}_ecc"
elif [ -d "$ACME_BASE/$DOMAIN" ]; then
  SRC_DIR="$ACME_BASE/$DOMAIN"
else
  echo "[-] No acme.sh cert directory found for $DOMAIN"
  exit 1
fi

if [ -f "$SRC_DIR/${DOMAIN}.key" ]; then
  SRC_KEY="$SRC_DIR/${DOMAIN}.key"
elif [ -f "$SRC_DIR/private.key" ]; then
  SRC_KEY="$SRC_DIR/private.key"
else
  echo "[-] Private key not found in $SRC_DIR"
  exit 1
fi

mkdir -p "$LIVE_DIR"
cp -f "$SRC_DIR/fullchain.cer" "$LIVE_DIR/fullchain.pem"
cp -f "$SRC_KEY" "$LIVE_DIR/privkey.pem"

chmod 644 "$LIVE_DIR/fullchain.pem"
chmod 600 "$LIVE_DIR/privkey.pem"

systemctl restart lsws
systemctl restart lscpd

echo "[+] Done for $DOMAIN"
echo "[+] Local cert:"
openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -dates

echo
echo "[+] Live cert:"
echo | openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -dates -subject -issuer

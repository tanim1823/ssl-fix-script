#!/bin/bash
set -e
DOMAIN="$1"
MODE="${2:-auto}"      # auto (default, renew-if-needed) | fresh (force delete + reissue)
MIN_DAYS="${MIN_DAYS:-20}"
ACME_HOME="/root/.acme.sh"

# If no domain given as argument, ask for it interactively
if [ -z "$DOMAIN" ]; then
  read -rp "Enter domain name: " DOMAIN
  if [ -z "$DOMAIN" ]; then
    echo "[-] No domain entered. Exiting."
    exit 1
  fi
fi

# If mode not given as argument, ask for it interactively too
if [ -z "$2" ]; then
  read -rp "Mode [auto/fresh] (default: auto): " MODE_INPUT
  if [ -n "$MODE_INPUT" ]; then
    MODE="$MODE_INPUT"
  fi
fi

LIVE_DIR="/etc/letsencrypt/live/$DOMAIN"

if [ "$MODE" = "fresh" ]; then
  echo "[+] FRESH mode: removing old cert for $DOMAIN from acme.sh ..."
  "$ACME_HOME/acme.sh" --remove -d "$DOMAIN" --ecc 2>/dev/null || true
  "$ACME_HOME/acme.sh" --remove -d "$DOMAIN" 2>/dev/null || true

  # delete leftover cert directories so acme.sh treats it as brand new
  rm -rf "$ACME_HOME/${DOMAIN}_ecc" "$ACME_HOME/${DOMAIN}"

  echo "[+] Issuing a brand new certificate for $DOMAIN ..."
  "$ACME_HOME/acme.sh" --issue -d "$DOMAIN" --force
  # ^ adjust validation method here, e.g. add: --webroot /path  OR  --standalone
  need_renew=0   # already issued, skip the renew block below
else
  need_renew=1
  if [ -f "$LIVE_DIR/fullchain.pem" ]; then
    end_date="$(openssl x509 -enddate -noout -in "$LIVE_DIR/fullchain.pem" | cut -d= -f2)"
    if [ -n "$end_date" ]; then
      end_ts="$(date -d "$end_date" +%s 2>/dev/null || true)"
      now_ts="$(date +%s)"
      if [ -n "$end_ts" ]; then
        remain_days=$(( (end_ts - now_ts) / 86400 ))
        echo "[+] Current live cert remaining days: $remain_days"
        if [ "$remain_days" -gt "$MIN_DAYS" ]; then
          need_renew=0
          echo "[+] More than $MIN_DAYS days left, skipping renew."
        fi
      fi
    fi
  fi

  if [ "$need_renew" -eq 1 ]; then
    echo "[+] Renewing certificate for $DOMAIN ..."
    "$ACME_HOME/acme.sh" --renew -d "$DOMAIN" --force || echo "[!] Renew returned non-zero. Will continue with latest available cert."
  fi
fi

if [ -d "$ACME_HOME/${DOMAIN}_ecc" ]; then
  SRC_DIR="$ACME_HOME/${DOMAIN}_ecc"
elif [ -d "$ACME_HOME/$DOMAIN" ]; then
  SRC_DIR="$ACME_HOME/$DOMAIN"
else
  echo "[-] No acme.sh cert directory found for $DOMAIN"
  exit 1
fi

if [ ! -f "$SRC_DIR/fullchain.cer" ]; then
  echo "[-] fullchain.cer not found in $SRC_DIR"
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

echo
echo "[+] Local cert dates:"
openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -dates
echo
echo "[+] Live cert check:"
echo | openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -dates -subject -issuer

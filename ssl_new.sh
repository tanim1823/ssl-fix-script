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
  echo "[+] FRESH mode: issuing a brand new key+cert for $DOMAIN (no delete needed) ..."

  # --- Auto-detect validation method ---
  WEBROOT=""

  # 1) Try to read webroot from an existing acme.sh config (if present)
  for CONF in "$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.conf" "$ACME_HOME/${DOMAIN}/${DOMAIN}.conf"; do
    if [ -f "$CONF" ]; then
      DETECTED="$(grep -oP "(?<=Le_Webroot=')[^']+" "$CONF" 2>/dev/null | head -n1)"
      if [ -n "$DETECTED" ] && [ -d "$DETECTED" ]; then
        WEBROOT="$DETECTED"
        echo "[+] Found webroot from acme.sh config: $WEBROOT"
        break
      fi
    fi
  done

  # 2) Try to detect from OpenLiteSpeed vhost config (docRoot line for this domain)
  if [ -z "$WEBROOT" ] && [ -d /usr/local/lsws/conf/vhosts ]; then
    VHCONF="$(grep -rl "docRoot" /usr/local/lsws/conf/vhosts/*/vhconf.conf 2>/dev/null | grep -i "$DOMAIN" | head -n1)"
    if [ -z "$VHCONF" ] && [ -f "/usr/local/lsws/conf/vhosts/${DOMAIN}/vhconf.conf" ]; then
      VHCONF="/usr/local/lsws/conf/vhosts/${DOMAIN}/vhconf.conf"
    fi
    if [ -n "$VHCONF" ] && [ -f "$VHCONF" ]; then
      DETECTED="$(grep -oP '(?<=docRoot\s{1,10}).*' "$VHCONF" | head -n1 | tr -d '[:space:]' | sed "s|\$VH_ROOT|/usr/local/lsws/${DOMAIN}|")"
      if [ -n "$DETECTED" ] && [ -d "$DETECTED" ]; then
        WEBROOT="$DETECTED"
        echo "[+] Found webroot from LiteSpeed vhost config: $WEBROOT"
      fi
    fi
  fi

  # 3) Try common directory patterns
  if [ -z "$WEBROOT" ]; then
    for CANDIDATE in "/home/${DOMAIN}/public_html" "/var/www/${DOMAIN}" "/var/www/html/${DOMAIN}" "/usr/local/lsws/${DOMAIN}/html"; do
      if [ -d "$CANDIDATE" ]; then
        WEBROOT="$CANDIDATE"
        echo "[+] Found webroot by common path guess: $WEBROOT"
        break
      fi
    done
  fi

  echo "[+] Issuing a brand new certificate for $DOMAIN ..."
  if [ -n "$WEBROOT" ]; then
    echo "[+] Using webroot validation: $WEBROOT"
    "$ACME_HOME/acme.sh" --issue -d "$DOMAIN" --webroot "$WEBROOT" --force
  else
    echo "[!] Could not auto-detect webroot. Falling back to standalone mode (needs port 80 free)."
    systemctl stop lsws 2>/dev/null || true
    "$ACME_HOME/acme.sh" --issue -d "$DOMAIN" --standalone --force
    ISSUE_RC=$?
    systemctl start lsws 2>/dev/null || true
    if [ "$ISSUE_RC" -ne 0 ]; then
      echo "[-] Standalone issue also failed. Please re-run and choose the correct method manually."
      exit 1
    fi
  fi
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

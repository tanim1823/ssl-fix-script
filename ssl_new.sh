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
  VHOST_CONF="/usr/local/lsws/conf/vhosts/${DOMAIN}/vhost.conf"

  # 0) CyberPanel/OpenLiteSpeed often defines a dedicated context block that
  #    redirects /.well-known/acme-challenge/ to a shared folder (e.g. Example/html).
  #    This takes priority since it overrides the normal docRoot for that path.
  if [ -f "$VHOST_CONF" ]; then
    ACME_LOC="$(grep -A3 'context[[:space:]]*/\.well-known/acme-challenge' "$VHOST_CONF" \
                | grep -oP '(?<=location[[:space:]])\s*\S+' | head -n1 | tr -d '[:space:]')"
    if [ -n "$ACME_LOC" ]; then
      DETECTED="${ACME_LOC%/.well-known/acme-challenge}"
      DETECTED="${DETECTED%/}"
      if [ -d "$DETECTED" ]; then
        WEBROOT="$DETECTED"
        echo "[+] Found dedicated ACME challenge webroot from vhost context rule: $WEBROOT"
      fi
    fi
  fi

  # 1) Try to read webroot from an existing acme.sh config (if present)
  if [ -z "$WEBROOT" ]; then
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
  fi

  # 2) Try to detect from the vhost's normal docRoot (only valid if no override context exists)
  if [ -z "$WEBROOT" ] && [ -f "$VHOST_CONF" ]; then
    DR="$(grep -oP '(?<=docRoot[[:space:]]).*' "$VHOST_CONF" | head -n1 | tr -d '[:space:]')"
    VH_ROOT="/home/${DOMAIN}"
    DETECTED="${DR//\$VH_ROOT/$VH_ROOT}"
    if [ -n "$DETECTED" ] && [ -d "$DETECTED" ]; then
      WEBROOT="$DETECTED"
      echo "[+] Found webroot from vhost docRoot: $WEBROOT"
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

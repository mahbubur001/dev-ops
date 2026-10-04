#!/bin/bash
#
# migrate-db-interactive.sh — run from your LAPTOP.
# Dumps a DB on the source server, pulls it local, pushes to target, restores.
# Uses peer auth (sudo -u postgres) on both servers — no DB passwords needed.
#
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
ask() { local p=$1 d=${2:-} v; read -rp "$(echo -e "${B}$p${NC}${d:+ [$d]}: ")" v; echo "${v:-$d}"; }

echo -e "${Y}── Source (old) server ──${NC}"
SRC_IP=$(ask "Source IP")
SRC_USER=$(ask "Source SSH user" "ubuntu")
SRC_PEM=$(ask "Source .pem path" "~/dev/source-key.pem")
SRC_DB=$(ask "Source database name")

echo -e "${Y}── Target (new) server ──${NC}"
TGT_IP=$(ask "Target IP")
TGT_USER=$(ask "Target SSH user" "ubuntu")
TGT_PEM=$(ask "Target .pem path" "~/dev/shopify.pem")
TGT_DB=$(ask "Target database name" "$SRC_DB")

# expand leading ~ in pem paths
SRC_PEM="${SRC_PEM/#\~/$HOME}"
TGT_PEM="${TGT_PEM/#\~/$HOME}"
DUMP="${SRC_DB}_$(date +%Y%m%d_%H%M%S).sql.gz"

echo
echo -e "${Y}Plan:${NC} $SRC_USER@$SRC_IP:$SRC_DB  →  $TGT_USER@$TGT_IP:$TGT_DB"
read -rp "$(echo -e "${B}Proceed? (y/N): ${NC}")" go
[[ "$go" == [yY] ]] || { echo "Aborted."; exit 0; }

echo -e "\n${B}▶ 1/4 Dumping on source…${NC}"
ssh -i "$SRC_PEM" "$SRC_USER@$SRC_IP" \
  "sudo -u postgres pg_dump '$SRC_DB' | gzip > /tmp/$DUMP"

echo -e "${B}▶ 2/4 Downloading to laptop…${NC}"
scp -i "$SRC_PEM" "$SRC_USER@$SRC_IP:/tmp/$DUMP" "/tmp/$DUMP"

echo -e "${B}▶ 3/4 Uploading to target…${NC}"
scp -i "$TGT_PEM" "/tmp/$DUMP" "$TGT_USER@$TGT_IP:/tmp/$DUMP"

echo -e "${B}▶ 4/4 Restoring on target…${NC}"
ssh -i "$TGT_PEM" "$TGT_USER@$TGT_IP" \
  "gunzip -c /tmp/$DUMP | sudo -u postgres psql -d '$TGT_DB' && echo '--- tables ---' && sudo -u postgres psql -d '$TGT_DB' -c '\dt'"

echo -e "\n${B}Cleaning up temp files…${NC}"
ssh -i "$SRC_PEM" "$SRC_USER@$SRC_IP" "rm -f /tmp/$DUMP"
ssh -i "$TGT_PEM" "$TGT_USER@$TGT_IP" "rm -f /tmp/$DUMP"
rm -f "/tmp/$DUMP"

echo -e "\n${G}✔ Migration complete: $SRC_DB → $TGT_DB${NC}"

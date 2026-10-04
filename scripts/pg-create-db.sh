#!/bin/bash

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────
LOG_FILE="/var/log/pg-create-db.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# ── Help ──────────────────────────────────────────────────
show_help() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Database & User Creator"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  echo "Usage:"
  echo "  sudo pg-create-db.sh -d DATABASE -u USERNAME [-p PASSWORD] [-e]"
  echo ""
  echo "Options:"
  echo "  -d    Database name to create"
  echo "  -u    Username (create new or use existing)"
  echo "  -p    Password for NEW user (required if user doesn't exist)"
  echo "  -e    Use existing user (skip user creation)"
  echo "  -h    Show this help"
  echo ""
  echo "Examples:"
  echo "  # Interactive mode"
  echo "  sudo pg-create-db.sh"
  echo ""
  echo "  # Create new database + new user"
  echo "  sudo pg-create-db.sh -d myapp_db -u myapp_user -p SecurePass123"
  echo ""
  echo "  # Create database with existing user"
  echo "  sudo pg-create-db.sh -d myapp_staging -u myapp_user -e"
}

# ── Validate input ────────────────────────────────────────
validate_input() {
  local INPUT=$1
  local TYPE=$2

  # Check for empty
  if [ -z "$INPUT" ]; then
    echo -e "${RED}❌ $TYPE cannot be empty${NC}"
    return 1
  fi

  # Check for valid characters (alphanumeric, underscore, hyphen)
  if [[ ! "$INPUT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}❌ $TYPE can only contain letters, numbers, underscore, and hyphen${NC}"
    return 1
  fi

  return 0
}

# ── Check if database exists ──────────────────────────────
check_database_exists() {
  local DB=$1
  sudo -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB"
  return $?
}

# ── Check if user exists ──────────────────────────────────
check_user_exists() {
  local USER=$1
  sudo -u postgres psql -t -c "SELECT 1 FROM pg_roles WHERE rolname='$USER'" 2>/dev/null | grep -q 1
  return $?
}

# ── Create database and user ──────────────────────────────
create_database_and_user() {
  local DB=$1
  local USER=$2
  local PASS=$3
  local USE_EXISTING=$4

  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Creating Database & User"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"

  # Check if database already exists
  if check_database_exists "$DB"; then
    echo -e "${RED}❌ Database '$DB' already exists!${NC}"
    echo "[$DATE] ❌ Database creation failed: $DB already exists" >> "$LOG_FILE"
    exit 1
  fi

  local USER_EXISTS=false
  if check_user_exists "$USER"; then
    USER_EXISTS=true
    if [ "$USE_EXISTING" = true ]; then
      echo -e "${GREEN}✅ Using existing user: $USER${NC}"
    else
      echo -e "${RED}❌ User '$USER' already exists! Use -e flag to use existing user.${NC}"
      echo "[$DATE] ❌ User creation failed: $USER already exists" >> "$LOG_FILE"
      exit 1
    fi
  else
    if [ "$USE_EXISTING" = true ]; then
      echo -e "${RED}❌ User '$USER' does not exist! Remove -e flag to create new user.${NC}"
      exit 1
    fi
    if [ -z "$PASS" ]; then
      echo -e "${RED}❌ Password required for new user creation${NC}"
      exit 1
    fi
  fi

  echo -e "  Database : ${GREEN}$DB${NC}"
  echo -e "  User     : ${GREEN}$USER${NC}"
  if [ "$USER_EXISTS" = true ]; then
    echo -e "  Mode     : ${YELLOW}Using existing user${NC}"
  else
    echo -e "  Password : ${GREEN}${PASS:0:3}***${NC}"
    echo -e "  Mode     : ${YELLOW}Creating new user${NC}"
  fi
  echo ""
  read -p "Proceed with creation? Type 'yes' to confirm: " CONFIRM

  if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}❌ Creation cancelled.${NC}"
    exit 0
  fi

  # Create user if needed
  if [ "$USER_EXISTS" = false ]; then
    echo -e "${BLUE}🔄 Creating user...${NC}"
    sudo -u postgres psql -c "CREATE USER \"$USER\" WITH PASSWORD '$PASS';" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✅ User '$USER' created successfully${NC}"
    else
      echo -e "${RED}❌ User creation failed${NC}"
      echo "[$DATE] ❌ User creation failed: $USER" >> "$LOG_FILE"
      exit 1
    fi
  fi

  echo -e "${BLUE}🔄 Creating database...${NC}"

  # Create database with owner
  sudo -u postgres psql -c "CREATE DATABASE \"$DB\" OWNER \"$USER\";" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Database '$DB' created successfully${NC}"
  else
    echo -e "${RED}❌ Database creation failed${NC}"
    echo "[$DATE] ❌ Database creation failed: $DB" >> "$LOG_FILE"
    # Rollback: drop the user if we just created it and database creation failed
    if [ "$USER_EXISTS" = false ]; then
      sudo -u postgres psql -c "DROP USER \"$USER\";" 2>/dev/null
    fi
    exit 1
  fi

  echo -e "${BLUE}🔄 Granting privileges...${NC}"

  # Grant database-level privileges
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB\" TO \"$USER\";" 2>/dev/null

  # Grant schema-level privileges (critical for table creation)
  sudo -u postgres psql -d "$DB" <<EOF 2>/dev/null
ALTER SCHEMA public OWNER TO "$USER";
GRANT ALL ON SCHEMA public TO "$USER";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$USER";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "$USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "$USER";
EOF

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ All privileges granted (database, schema, tables, sequences)${NC}"
  else
    echo -e "${YELLOW}⚠️  Some privileges grant warning (database still created)${NC}"
  fi

  echo ""
  echo -e "${GREEN}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✅ Setup Complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"
  echo -e "  Database : ${GREEN}$DB${NC}"
  echo -e "  User     : ${GREEN}$USER${NC}"
  if [ "$USER_EXISTS" = false ]; then
    echo -e "  Password : ${GREEN}$PASS${NC}"
    echo ""
    echo -e "${YELLOW}Connection string:${NC}"
    echo -e "  postgresql://$USER:$PASS@localhost:5432/$DB"
    echo ""
    echo -e "${YELLOW}Test connection:${NC}"
    echo -e "  PGPASSWORD='$PASS' psql -U $USER -d $DB -h localhost"
  else
    echo ""
    echo -e "${YELLOW}Connection string:${NC}"
    echo -e "  postgresql://$USER:<password>@localhost:5432/$DB"
    echo ""
    echo -e "${YELLOW}Test connection:${NC}"
    echo -e "  PGPASSWORD='<password>' psql -U $USER -d $DB -h localhost"
  fi
  echo ""

  if [ "$USER_EXISTS" = true ]; then
    echo "[$DATE] ✅ Database created with existing user: $DB / $USER" >> "$LOG_FILE"
  else
    echo "[$DATE] ✅ Database and user created: $DB / $USER" >> "$LOG_FILE"
  fi
}

# ── Interactive mode ──────────────────────────────────────
interactive_mode() {
  echo -e "${BLUE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PostgreSQL Database & User Creator"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${NC}"

  # Get database name
  while true; do
    read -p "Enter database name: " DB
    if validate_input "$DB" "Database name"; then
      break
    fi
  done

  # Get username
  while true; do
    read -p "Enter username: " USER
    if validate_input "$USER" "Username"; then
      break
    fi
  done

  # Check if user exists
  local USE_EXISTING=false
  if check_user_exists "$USER"; then
    echo -e "${YELLOW}ℹ️  User '$USER' already exists${NC}"
    read -p "Use existing user? (yes/no): " USE_EXISTING_INPUT
    if [ "$USE_EXISTING_INPUT" = "yes" ]; then
      USE_EXISTING=true
      PASS=""
    else
      echo -e "${RED}❌ Please choose a different username${NC}"
      exit 1
    fi
  fi

  # Get password only if creating new user
  if [ "$USE_EXISTING" = false ]; then
    while true; do
      read -s -p "Enter password: " PASS
      echo ""
      if [ -z "$PASS" ]; then
        echo -e "${RED}❌ Password cannot be empty${NC}"
        continue
      fi
      if [ ${#PASS} -lt 8 ]; then
        echo -e "${YELLOW}⚠️  Warning: Password is less than 8 characters${NC}"
        read -p "Continue anyway? (yes/no): " CONTINUE
        if [ "$CONTINUE" != "yes" ]; then
          continue
        fi
      fi
      break
    done
  fi

  create_database_and_user "$DB" "$USER" "$PASS" "$USE_EXISTING"
}

# ── Parse args ────────────────────────────────────────────
DB=""
USER=""
PASS=""
USE_EXISTING=false

while getopts "d:u:p:eh" opt; do
  case $opt in
    d) DB="$OPTARG" ;;
    u) USER="$OPTARG" ;;
    p) PASS="$OPTARG" ;;
    e) USE_EXISTING=true ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

# ── Main ──────────────────────────────────────────────────
if [ -z "$DB" ] && [ -z "$USER" ] && [ -z "$PASS" ]; then
  interactive_mode
elif [ -n "$DB" ] && [ -n "$USER" ]; then
  if ! validate_input "$DB" "Database name"; then exit 1; fi
  if ! validate_input "$USER" "Username"; then exit 1; fi

  # Validate password requirement
  if [ "$USE_EXISTING" = false ] && [ -z "$PASS" ]; then
    echo -e "${RED}❌ Error: Password (-p) required when creating new user${NC}"
    echo -e "${YELLOW}💡 Use -e flag to use existing user without password${NC}"
    echo ""
    show_help
    exit 1
  fi

  create_database_and_user "$DB" "$USER" "$PASS" "$USE_EXISTING"
else
  echo -e "${RED}❌ Error: Database (-d) and user (-u) are required${NC}"
  echo ""
  show_help
  exit 1
fi

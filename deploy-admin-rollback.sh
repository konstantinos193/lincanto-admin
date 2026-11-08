#!/bin/bash
# Rollback Script — admin.smholdings.gr panel. Switches back to the previous colour.
# Usage: ./deploy-admin-rollback.sh <color>
# Example: ./deploy-admin-rollback.sh blue

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -ne 1 ]; then
    echo -e "${RED}Usage: $0 <color>${NC}"
    echo -e "${YELLOW}Example: $0 blue${NC}"
    exit 1
fi

ROLLBACK_COLOR=$1
if [ "$ROLLBACK_COLOR" != "green" ] && [ "$ROLLBACK_COLOR" != "blue" ]; then
    echo -e "${RED}Error: Color must be 'green' or 'blue'${NC}"
    exit 1
fi
FAILED_COLOR=$([ "$ROLLBACK_COLOR" = "green" ] && echo "blue" || echo "green")

echo -e "${GREEN}=== Rollback: admin.smholdings.gr panel ===${NC}"
echo -e "${YELLOW}Rolling back to: $ROLLBACK_COLOR${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Step 1: rollback container must exist
echo -e "${YELLOW}[1/3] Checking admin-$ROLLBACK_COLOR...${NC}"
if ! docker ps -a --format '{{.Names}}' | grep -q "^admin-$ROLLBACK_COLOR$"; then
    echo -e "${RED}✗ admin-$ROLLBACK_COLOR does not exist!${NC}"
    exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -q "^admin-$ROLLBACK_COLOR$"; then
    echo -e "${YELLOW}Starting admin-$ROLLBACK_COLOR...${NC}"
    docker start "admin-$ROLLBACK_COLOR"
fi

# Step 2: wait for healthy
echo -e "${YELLOW}[2/3] Waiting for admin-$ROLLBACK_COLOR to be healthy...${NC}"
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' "admin-$ROLLBACK_COLOR" 2>/dev/null || echo "starting")
    if [ "$HEALTH_STATUS" = "healthy" ]; then
        echo -e "${GREEN}✓ Container is healthy!${NC}"
        break
    elif [ "$HEALTH_STATUS" = "unhealthy" ]; then
        echo -e "${RED}✗ Container is unhealthy!${NC}"
        docker logs "admin-$ROLLBACK_COLOR"
        exit 1
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo -e "${YELLOW}Waiting... ($RETRY_COUNT/$MAX_RETRIES) - Status: $HEALTH_STATUS${NC}"
    sleep 2
done
if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}✗ Health check timeout!${NC}"
    docker logs "admin-$ROLLBACK_COLOR"
    exit 1
fi

# Repoint Traefik before the failed colour is stopped: deploy-admin-route.sh
# returns 0 only once Traefik has loaded the rollback upstream and a request
# through it is answered.
echo -e "${YELLOW}Repointing Traefik to admin-$ROLLBACK_COLOR...${NC}"
if ! bash "$SCRIPT_DIR/deploy-admin-route.sh" "$ROLLBACK_COLOR"; then
    echo -e "${RED}✗ Traefik did not take the rollback colour - nothing stopped${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Traefik serves admin-$ROLLBACK_COLOR${NC}"

# Step 3: stop the failed container
echo -e "${YELLOW}[3/3] Stopping failed admin-$FAILED_COLOR...${NC}"
if docker ps --format '{{.Names}}' | grep -q "^admin-$FAILED_COLOR$"; then
    docker stop "admin-$FAILED_COLOR"
    echo -e "${GREEN}✓ Stopped admin-$FAILED_COLOR${NC}"
else
    echo -e "${YELLOW}No admin-$FAILED_COLOR container running${NC}"
fi

echo "$ROLLBACK_COLOR" > /root/.active_color_admin

echo -e "${GREEN}=== Rollback Complete ===${NC}"
echo -e "${GREEN}✓ admin.smholdings.gr serves admin-$ROLLBACK_COLOR${NC}"

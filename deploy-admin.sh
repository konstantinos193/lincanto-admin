#!/bin/bash
# Zero-Downtime Deployment Script — admin.smholdings.gr panel (Next.js standalone)
# Usage: ./deploy-admin.sh <color> <image>
# Example: ./deploy-admin.sh green ghcr.io/konstantinos193/lincanto-admin:abc123
#
# Same shape as the API's /root/deploy.sh and HotelPoint's
# deploy-zero-downtime.sh: two colours on stefanos-net, a Docker health check,
# then the edge repoint — Traefik here, verified through its own API by
# deploy-admin-route.sh before the old colour is allowed to stop.
#
# Live copy: /root/deploy-admin.sh on the VPS. This file is the source of
# truth; copy it over after editing.
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -ne 2 ]; then
    echo -e "${RED}Usage: $0 <color> <image>${NC}"
    echo -e "${YELLOW}Example: $0 green ghcr.io/konstantinos193/lincanto-admin:abc123${NC}"
    exit 1
fi

DEPLOY_COLOR=$1
NEW_IMAGE=$(echo "$2" | tr '[:upper:]' '[:lower:]')

if [ "$DEPLOY_COLOR" != "green" ] && [ "$DEPLOY_COLOR" != "blue" ]; then
    echo -e "${RED}Error: Color must be 'green' or 'blue'${NC}"
    exit 1
fi
OTHER_COLOR=$([ "$DEPLOY_COLOR" = "green" ] && echo "blue" || echo "green")

echo -e "${GREEN}=== admin.smholdings.gr panel deploy ===${NC}"
echo -e "${YELLOW}Deploy Color: $DEPLOY_COLOR${NC}"
echo -e "${YELLOW}New Image: $NEW_IMAGE${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Tagged deploy images per repo to retain: the live image plus one rollback
# target. The disk is shared with libsql — SQLITE_IOERR on a full volume is
# the failure this is a budget against.
KEEP_IMAGES=${KEEP_IMAGES:-2}

# Free GB the pull must have before it starts. Site images are ~500MB.
MIN_FREE_GB=${MIN_FREE_GB:-2}

# Registry namespace this host deploys. Reclaim sweeps every repo under it:
# backend and site images share the filesystem.
MANAGED_IMAGE_PREFIX=${MANAGED_IMAGE_PREFIX:-ghcr.io/konstantinos193}

# Host deploy lock. The API deploy (deploy.sh) does not take it today, but
# the site, admin and licanto fleets all will — the lock is what stops two
# pipelines reclaiming each other's in-flight pull.
LOCK_FILE=/var/lock/stefanos-deploy.lock
LOCK_WAIT=900

exec 9>"$LOCK_FILE" || { echo -e "${RED}Error: cannot open $LOCK_FILE${NC}"; exit 1; }
echo -e "${YELLOW}Acquiring host deploy lock...${NC}"
if ! flock -w "$LOCK_WAIT" 9; then
    echo -e "${RED}✗ Timed out after ${LOCK_WAIT}s waiting for another deploy to release the lock${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Deploy lock acquired${NC}"

# =============================================================================
# MEMORY BUDGET
# =============================================================================
# The box is a 1.6GB VPS that also runs libsql, redis, Traefik and the API.
# An uncapped Next.js server is part of global OOM pressure, and a global OOM
# kills the biggest process — which is libsql, the database.
#
# --memory-swap equal to --memory disables swap for the container: a Next.js
# server that is paging is one whose requests time out anyway; dying and
# being restarted by --restart unless-stopped is the better failure.
#
# 384m against ~150MB measured for a standalone server. Sized for a leak
# backstop, not as a diet.
HOST_MEMORY_MB=${HOST_MEMORY_MB:-$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)}
HOST_MEMORY_MB=${HOST_MEMORY_MB:-2048}

if [ "$HOST_MEMORY_MB" -ge 7168 ]; then
    SITE_MEM_LIMIT=${SITE_MEM_LIMIT:-1g}
    SITE_MEM_RESERVATION=${SITE_MEM_RESERVATION:-256m}
elif [ "$HOST_MEMORY_MB" -ge 3584 ]; then
    SITE_MEM_LIMIT=${SITE_MEM_LIMIT:-640m}
    SITE_MEM_RESERVATION=${SITE_MEM_RESERVATION:-192m}
else
    SITE_MEM_LIMIT=${SITE_MEM_LIMIT:-384m}
    SITE_MEM_RESERVATION=${SITE_MEM_RESERVATION:-128m}
fi

# Memory-pressure gate. /proc/pressure/memory, not `free`: PSI is the
# kernel's own measure of tasks stalled on memory. Under MEM_PSI_MAX the host
# is not stalling right now; wait up to MEM_PSI_WAITs for it to calm down,
# then proceed regardless — a deploy that never runs is a broken pipeline.
MEM_PSI_MAX="${MEM_PSI_MAX:-25}"
MEM_PSI_WAIT="${MEM_PSI_WAIT:-300}"
if [ -r /proc/pressure/memory ]; then
    psi_full_avg60() {
        sed -n 's/^full .*avg60=\([0-9.]*\).*/\1/p' /proc/pressure/memory | cut -d. -f1
    }
    psi_waited=0
    while [ "$(psi_full_avg60)" -ge "$MEM_PSI_MAX" ] 2>/dev/null; do
        if [ "$psi_waited" -ge "$MEM_PSI_WAIT" ]; then
            echo -e "${YELLOW}⚠ Host still under memory pressure after ${MEM_PSI_WAIT}s (full avg60=$(psi_full_avg60)%) - proceeding anyway${NC}"
            free -m | sed 's/^/    /'
            break
        fi
        if [ "$psi_waited" -eq 0 ]; then
            echo -e "${YELLOW}Host under memory pressure (full avg60=$(psi_full_avg60)%, limit ${MEM_PSI_MAX}%) - waiting for it to settle...${NC}"
        fi
        sleep 15
        psi_waited=$((psi_waited + 15))
    done
    echo -e "${GREEN}✓ Memory pressure OK (full avg60=$(psi_full_avg60)%, MemAvailable $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo) MB)${NC}"
fi

# The lock removes the known cause of transient pull failures; retry anyway
# so a registry blip cannot fail an otherwise good deploy.
pull_with_retry() {
    local image="$1" attempt=1 max=3
    while true; do
        if docker pull "$image"; then
            return 0
        fi
        if [ "$attempt" -ge "$max" ]; then
            echo -e "${RED}✗ Pull failed after $max attempts${NC}"
            return 1
        fi
        echo -e "${YELLOW}Pull failed (attempt $attempt/$max), retrying in $((attempt * 10))s...${NC}"
        sleep $((attempt * 10))
        attempt=$((attempt + 1))
    done
}

free_bytes() {
    df -B1 --output=avail /var/lib/docker 2>/dev/null | tail -1
}
human_gb() {
    awk -v b="${1:-0}" 'BEGIN { printf "%.1fGB", b / 1073741824 }'
}

# Every image ID a container still points at — the live container and the
# idle rollback target both pin their image.
in_use_image_ids() {
    docker ps -a -q | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null | sort -u
}

# Tags of $repo, newest first. Deploy tags are `main-<sha>`/`main-<N>`;
# anything with no numeric suffix sorts first and is never surplus — it is
# something a human staged (site:bootstrap), and this will not guess at it.
repo_tags_newest_first() {
    docker images "$1" --format '{{.Repository}}:{{.Tag}}' \
        | grep -v ':<none>$' \
        | while read -r ref; do
            case "${ref##*:}" in
                *-[0-9]*) printf '%s\t%s\n' "${ref##*-}" "$ref" ;;
                *)         printf '%s\t%s\n' 999999999 "$ref" ;;
            esac
        done \
        | sort -k1,1nr \
        | cut -f2
}

surplus_image_ids() {
    local repo="$1" keep="$2"
    repo_tags_newest_first "$repo" \
        | tail -n +"$((keep + 1))" \
        | while read -r ref; do
            docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null
        done
}

# Drop all but the newest $keep tags of $repo, skipping images a container
# still references.
cleanup_old_images() {
    local repo="$1" keep="${2:-2}"
    local in_use_ids
    in_use_ids=$(in_use_image_ids)
    repo_tags_newest_first "$repo" \
        | tail -n +"$((keep + 1))" \
        | while read -r ref; do
            local id
            id=$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null)
            if [ -n "$id" ] && printf '%s\n' "$in_use_ids" | grep -qxF "$id"; then
                echo -e "  ${YELLOW}pinned by a container, kept: $ref${NC}"
            elif docker rmi "$ref" >/dev/null 2>&1; then
                echo -e "  ${GREEN}removed: $ref${NC}"
            else
                echo -e "  ${YELLOW}skipped: $ref${NC}"
            fi
        done
}

# Remove stopped containers pinning an image outside the keep-N window. A
# stopped container whose image is still retained is the rollback target and
# is left alone; running containers are never considered.
release_stale_pins() {
    local repo="$1" keep="$2"
    local surplus_ids
    surplus_ids=$(surplus_image_ids "$repo" "$keep")
    [ -n "$surplus_ids" ] || return 0
    docker ps -a --filter status=exited --filter status=created --filter status=dead \
              --format '{{.ID}} {{.Names}}' \
        | while read -r cid cname; do
            local id
            id=$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null) || continue
            if printf '%s\n' "$surplus_ids" | grep -qxF "$id" \
               && docker rm -f "$cid" >/dev/null 2>&1; then
                echo -e "  ${GREEN}removed stopped container pinning a dropped image: $cname${NC}"
            fi
        done
}

reclaim_disk() {
    local aggressive="${1:-}"
    echo -e "${YELLOW}Reclaiming disk (before: $(human_gb "$(free_bytes)") free)...${NC}"

    docker image prune -f >/dev/null 2>&1 || true
    docker builder prune -f >/dev/null 2>&1 || true

    local repo
    for repo in $(docker images --format '{{.Repository}}' \
                    | grep -F "$MANAGED_IMAGE_PREFIX/" | sort -u); do
        if [ -n "$aggressive" ]; then
            release_stale_pins "$repo" "$KEEP_IMAGES"
        fi
        cleanup_old_images "$repo" "$KEEP_IMAGES"
    done

    if [ -n "$aggressive" ]; then
        # Container stdout logs of the long-lived hand-started containers —
        # libsql, redis, traefik were created with the uncapped json-file
        # default. Truncating a live json.log is safe: the daemon holds the
        # fd open and appends from offset zero.
        find /var/lib/docker/containers -name '*-json.log' -size +20M \
            -exec truncate -s 0 {} \; >/dev/null 2>&1 || true

        # Unreferenced images from OUTSIDE the managed namespace — base
        # images left by manual builds. NOT `docker image prune -a`: that
        # deletes the keep-N rollback target, which has no container by
        # definition.
        local unref_in_use ref id
        unref_in_use=$(in_use_image_ids)
        docker images --format '{{.Repository}}:{{.Tag}}' \
            | grep -v '^<none>' | grep -v ':<none>$' \
            | grep -v "^$MANAGED_IMAGE_PREFIX/" \
            | while read -r ref; do
                id=$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null) || continue
                if [ -n "$id" ] && printf '%s\n' "$unref_in_use" | grep -qxF "$id"; then
                    continue
                fi
                if docker rmi "$ref" >/dev/null 2>&1; then
                    echo -e "  ${GREEN}removed unreferenced image: $ref${NC}"
                fi
            done
    fi

    echo -e "${GREEN}✓ Reclaim done (after: $(human_gb "$(free_bytes)") free)${NC}"
}

ensure_disk_space() {
    local need=$((MIN_FREE_GB * 1073741824))
    local avail
    avail=$(free_bytes)
    if [ "${avail:-0}" -ge "$need" ]; then
        echo -e "${GREEN}✓ Disk OK ($(human_gb "$avail") free, need ${MIN_FREE_GB}GB)${NC}"
        return 0
    fi
    echo -e "${YELLOW}Only $(human_gb "$avail") free, need ${MIN_FREE_GB}GB${NC}"
    reclaim_disk aggressive
    avail=$(free_bytes)
    if [ "${avail:-0}" -ge "$need" ]; then
        return 0
    fi
    # Warn, do not block: the prediction "it won't fit" has been wrong often
    # enough to be worse than the failure it guards. A real shortfall now
    # fails at the pull, is retried, and reclaims on exit.
    echo -e "${YELLOW}  Proceeding anyway - the pull may still fit, and a failed one reclaims on exit${NC}"
    docker ps -a --format '    {{.Names}}  ->  {{.Image}}  ({{.Status}})'
    return 0
}

# Kernel OOM bias for the shared box: a global OOM ignores cgroup ceilings
# and kills the largest process. libsql is the thing whose loss is an outage;
# the site is the thing that can be re-pulled.
oom_bias_for() {
    case "$1" in
        libsql)                          echo -900 ;;
        redis)                           echo -800 ;;
        stefanos-traefik)                echo -700 ;;
        stefanos-blue|stefanos-green)    echo -500 ;;
        site-blue|site-green)            echo -200 ;;
        lincanto-blue|lincanto-green)    echo -300 ;;
        admin-blue|admin-green)          echo -100 ;;
        *) echo "" ;;
    esac
}

ensure_oom_priorities() {
    local name bias cid procs pid applied=0
    while read -r name; do
        [ -n "$name" ] || continue
        bias=$(oom_bias_for "$name")
        [ -n "$bias" ] || continue
        cid=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null) || continue
        procs=/sys/fs/cgroup/system.slice/docker-$cid.scope/cgroup.procs
        if [ -r "$procs" ]; then
            for pid in $(cat "$procs" 2>/dev/null); do
                echo "$bias" > "/proc/$pid/oom_score_adj" 2>/dev/null || true
            done
        else
            pid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null)
            [ "${pid:-0}" -gt 0 ] 2>/dev/null \
                && echo "$bias" > "/proc/$pid/oom_score_adj" 2>/dev/null || true
        fi
        applied=$((applied + 1))
    done <<< "$(docker ps --format '{{.Names}}')"
    echo -e "${GREEN}  ✓ OOM priorities set on $applied container(s); libsql and Traefik are last to be killed${NC}"
}

on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo -e "${YELLOW}Deploy failed - reclaiming so this run's image does not block the next one...${NC}"
        reclaim_disk aggressive || true
    fi
}
trap on_exit EXIT

# Deploy an image already in the local store instead of fetching from ghcr —
# the bootstrap/staging path before CI is wired. Off by default: a normal
# deploy must take the image CI actually published.
SKIP_PULL=${SKIP_PULL:-false}

# Step 1: Login to GitHub Container Registry
if [ "$SKIP_PULL" = "true" ]; then
    echo -e "${YELLOW}[1/6] SKIP_PULL=true - skipping registry login${NC}"
elif [ -n "$GITHUB_TOKEN" ]; then
    echo -e "${YELLOW}[1/6] Logging in to GitHub Container Registry...${NC}"
    echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
else
    echo -e "${RED}Error: GITHUB_TOKEN not set${NC}"
    exit 1
fi

# Step 2: Pull new image
if [ "$SKIP_PULL" = "true" ]; then
    echo -e "${YELLOW}[2/6] SKIP_PULL=true - using local image${NC}"
    if ! docker image inspect "$NEW_IMAGE" >/dev/null 2>&1; then
        echo -e "${RED}✗ SKIP_PULL=true but $NEW_IMAGE is not in the local image store${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Found $NEW_IMAGE locally${NC}"
else
    echo -e "${YELLOW}[2/6] Pulling new image...${NC}"
    ensure_disk_space
    pull_with_retry "$NEW_IMAGE"
fi

# Step 3: Ensure Docker network exists
echo -e "${YELLOW}[3/7] Ensuring stefanos-net exists...${NC}"
if ! docker network ls --format '{{.Name}}' | grep -q "^stefanos-net$"; then
    docker network create stefanos-net
    echo -e "${GREEN}✓ Network created${NC}"
else
    echo -e "${GREEN}✓ Network already exists${NC}"
fi

# Step 4: Stop old container of the same color (if exists)
echo -e "${YELLOW}[4/7] Stopping old $DEPLOY_COLOR container (if exists)...${NC}"
if docker ps -a --format '{{.Names}}' | grep -q "^admin-$DEPLOY_COLOR$"; then
    docker stop "admin-$DEPLOY_COLOR" || true
    docker rm "admin-$DEPLOY_COLOR" || true
fi

# Step 5: Start new container. Loopback-published port is only for this
# script's probes; Traefik reaches the container by name on stefanos-net.
echo -e "${YELLOW}[5/7] Starting new $DEPLOY_COLOR container...${NC}"
if [ "$DEPLOY_COLOR" = "green" ]; then
    PORT=3051
else
    PORT=3050
fi

# No runtime env file: every config value the app reads is NEXT_PUBLIC_*,
# inlined into the bundle by `pnpm build` via the Dockerfile's build args.
docker run -d \
    --name "admin-$DEPLOY_COLOR" \
    --restart unless-stopped \
    --log-opt max-size=10m --log-opt max-file=3 \
    --memory "$SITE_MEM_LIMIT" \
    --memory-swap "$SITE_MEM_LIMIT" \
    --memory-reservation "$SITE_MEM_RESERVATION" \
    --network stefanos-net \
    -p "127.0.0.1:${PORT}:3000" \
    -e NODE_ENV=production \
    -e NEXT_TELEMETRY_DISABLED=1 \
    -e PORT=3000 \
    --health-cmd="wget -q -O /dev/null http://127.0.0.1:3000/logoetc.png || exit 1" \
    --health-interval=60s \
    --health-start-interval=2s \
    --health-timeout=5s \
    --health-retries=3 \
    --health-start-period=60s \
    "$NEW_IMAGE"

# Step 6: Wait for healthy
echo -e "${YELLOW}[6/7] Waiting for $DEPLOY_COLOR container to be healthy...${NC}"
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' "admin-$DEPLOY_COLOR" 2>/dev/null || echo "starting")
    if [ "$HEALTH_STATUS" = "healthy" ]; then
        echo -e "${GREEN}✓ Container is healthy!${NC}"
        ensure_oom_priorities
        break
    elif [ "$HEALTH_STATUS" = "unhealthy" ]; then
        echo -e "${RED}✗ Container is unhealthy!${NC}"
        docker logs "admin-$DEPLOY_COLOR"
        exit 1
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo -e "${YELLOW}Waiting... ($RETRY_COUNT/$MAX_RETRIES) - Status: $HEALTH_STATUS${NC}"
    sleep 2
done
if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}✗ Health check timeout!${NC}"
    docker logs "admin-$DEPLOY_COLOR"
    exit 1
fi

# Repoint Traefik while the old colour is still running. deploy-admin-route.sh
# only returns 0 once Traefik's API shows the new upstream loaded and a
# request through Traefik is answered — the old colour stops after nothing
# is routed to it, not before.
echo -e "${YELLOW}Repointing Traefik to admin-$DEPLOY_COLOR...${NC}"
if ! bash "$SCRIPT_DIR/deploy-admin-route.sh" "$DEPLOY_COLOR"; then
    echo -e "${RED}✗ Traefik cutover not confirmed - $OTHER_COLOR left running and serving${NC}"
    echo -e "${RED}  Check: tail -20 /etc/stefanos/traefik/logs/traefik.log${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Cutover verified through Traefik${NC}"

# Step 7: Stop old container (other color)
echo -e "${YELLOW}[7/7] Stopping old $OTHER_COLOR container...${NC}"
if docker ps --format '{{.Names}}' | grep -q "^admin-$OTHER_COLOR$"; then
    docker stop "admin-$OTHER_COLOR"
    echo -e "${GREEN}✓ Stopped $OTHER_COLOR container${NC}"
else
    echo -e "${YELLOW}No $OTHER_COLOR container running (first deployment)${NC}"
fi

echo "$DEPLOY_COLOR" > /root/.active_color_admin

echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo -e "${GREEN}✓ New $DEPLOY_COLOR container is running and healthy${NC}"
echo -e "${GREEN}✓ Old $OTHER_COLOR container has been stopped${NC}"
echo -e "${GREEN}✓ Traefik points at admin-$DEPLOY_COLOR${NC}"

echo -e "${YELLOW}Cleaning up old Docker images (keeping newest $KEEP_IMAGES per repo)...${NC}"
reclaim_disk
echo -e "${GREEN}✓ Docker image cleanup complete${NC}"

#!/bin/bash

set -e  # Stop script execution on error

NGINX_CONF_PATH="./docker/nginx/active_backend.conf"
NGINX_CONTAINER="app"
ENV_FILE=".env"

build_containers() {
    echo "📦 Building Docker containers..."
    docker compose build
    echo "✅ Docker containers built successfully."
}

prepare_nginx_config() {
    if [ ! -d "./docker/nginx" ]; then
        echo "📂 Nginx directory not found. Creating it..."
        mkdir -p ./docker/nginx
        echo "✅ Nginx directory created."
    fi
}

update_nginx_config() {
    local active_color=$1
    echo "🔄 Updating Nginx configuration to route traffic to '$active_color' containers..."

    cat > "$NGINX_CONF_PATH" <<EOL
upstream app_backend {
    server $active_color:9000 max_fails=3 fail_timeout=30s;
}
EOL

    echo "📋 Copying Nginx configuration to the container..."
    docker cp "$NGINX_CONF_PATH" "$NGINX_CONTAINER:/etc/nginx/conf.d/active_backend.conf"
    echo "🔁 Reloading Nginx to apply the new configuration..."
    docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1
    echo "✅ Nginx configuration updated and reloaded successfully."
}

wait_for_health() {
    local container_prefix=$1
    local retries=5
    local unhealthy_found
    echo "⏳ Waiting for containers with prefix '$container_prefix' to become healthy..."

    while (( retries > 0 )); do
        unhealthy_found=false

        for container_name in $(docker ps --filter "name=$container_prefix" --format "{{.Names}}"); do
            health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$container_name" || echo "unknown")
            if [[ "$health_status" != "healthy" ]]; then
                unhealthy_found=true
                echo "🚧 Container '$container_name' is not ready. Current status: $health_status."
            fi
        done

        if ! $unhealthy_found; then
            echo "✅ All containers with prefix '$container_prefix' are healthy."
            return 0
        fi

        echo "⏳ Retrying... ($retries retries left)"
        ((retries--))
        sleep 5
    done

    echo "❌ Error: Some containers with prefix '$container_prefix' are not healthy. Aborting deployment."
    rollback
    exit 0
}

rollback() {
    echo "🛑 Rolling back deployment. Ensuring the active environment remains intact."

    if [ -n "$PREVIOUS_COLOR" ]; then
        echo "🔄 Restoring CONTAINER_COLOR=$PREVIOUS_COLOR in .env."
        sed -i.bak "s/^CONTAINER_COLOR=.*/CONTAINER_COLOR=$PREVIOUS_COLOR/" "$ENV_FILE"
        rm -f "$ENV_FILE.bak"
        echo "✅ Restored CONTAINER_COLOR=$PREVIOUS_COLOR in .env."
    else
        echo "🚧  No previous CONTAINER_COLOR found to restore."
    fi

    if docker ps --filter "name=green" --format "{{.Names}}" | grep -q "green"; then
        echo "✅ Active environment 'green' remains intact."
        echo "🛑 Stopping and removing 'blue' containers..."
        docker compose stop "blue" >/dev/null 2>&1 || true
        docker compose rm -f "blue" >/dev/null 2>&1 || true
    elif docker ps --filter "name=blue" --format "{{.Names}}" | grep -q "blue"; then
        echo "✅ Active environment 'blue' remains intact."
        echo "🛑 Stopping and removing 'green' containers..."
        docker compose stop "green" >/dev/null 2>&1 || true
        docker compose rm -f "green" >/dev/null 2>&1 || true
    else
        echo "❌ No active environment detected after rollback. Manual intervention might be needed."
    fi

    echo "🔄 Rollback completed."
}

update_env_file() {
    local active_color=$1

    # check if .env file exists
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌ .env file not found. Creating a new one..."
        echo "CONTAINER_COLOR=$active_color" > "$ENV_FILE"
        echo "✅ Created .env file with CONTAINER_COLOR=$active_color."
        return
    fi

    # backup previous CONTAINER_COLOR value
    if grep -q "^CONTAINER_COLOR=" "$ENV_FILE"; then
        PREVIOUS_COLOR=$(grep "^CONTAINER_COLOR=" "$ENV_FILE" | cut -d '=' -f 2)
        echo "♻️  Backing up previous CONTAINER_COLOR=$PREVIOUS_COLOR."
    else
        PREVIOUS_COLOR=""
    fi

    # update CONTAINER_COLOR value in .env
    if grep -q "^CONTAINER_COLOR=" "$ENV_FILE"; then
        sed -i.bak "s/^CONTAINER_COLOR=.*/CONTAINER_COLOR=$active_color/" "$ENV_FILE"
        echo "🔄 Updated CONTAINER_COLOR=$active_color in .env"
    else
        echo "CONTAINER_COLOR=$active_color" >> "$ENV_FILE"
        echo "🖋️ Added CONTAINER_COLOR=$active_color to .env"
    fi

    # remove backup file
    if [ -f "$ENV_FILE.bak" ]; then
        rm "$ENV_FILE.bak"
    fi
}

install_dependencies() {
    local container=$1
    echo "📥 Installing dependencies in container '$container'..."

    # Install Laravel dependencies
    docker exec -u root -it "$container" bash -c "composer install --no-dev --optimize-autoloader"
    docker exec -u root -it "$container" bash -c "mkdir -p database && touch database/database.sqlite"

    # Permissions setup
    docker exec -u root -it "$container" bash -c "chown www-data:www-data -R ./storage ./bootstrap ./database"
    docker exec -u root -it "$container" bash -c "chmod -R 775 ./storage ./bootstrap/cache"

    # Clear caches and run migrations
    docker exec -u root -it "$container" bash -c "php artisan cache:clear"
    docker exec -u root -it "$container" bash -c "php artisan config:clear"
    docker exec -u root -it "$container" bash -c "php artisan route:clear"
    docker exec -u root -it "$container" bash -c "php artisan view:clear"
    docker exec -u root -it "$container" bash -c "php artisan migrate --force"

    echo "✅ Dependencies installed and database initialized successfully in container '$container'."
}

deploy() {
    local active=$1
    local new=$2

    # Update .env before deploying
    update_env_file "$new"
    echo "🚀 Starting deployment. Current active environment: '$active'. Deploying to '$new'..."
    docker compose --profile "$new" up -d
    wait_for_health "$new"
    install_dependencies "$new"
    update_nginx_config "$new"
    echo "🗑️  Removing old environment: '$active'..."
    echo "🛑 Stopping '$active' containers..."
    docker compose stop $active >/dev/null 2>&1 || true
    echo "🗑️  Removing '$active' containers..."
    docker compose rm -f $active >/dev/null 2>&1 || true
    update_env_file "$new"
    echo "✅ Deployment to '$new' completed successfully."
}

get_active_container() {
    if [ -f "$ENV_FILE" ] && grep -q "CONTAINER_COLOR" "$ENV_FILE"; then
        grep "CONTAINER_COLOR" "$ENV_FILE" | cut -d '=' -f 2
    else
        echo ""
    fi
}

# Main script logic
prepare_nginx_config
build_containers

ACTIVE_COLOR=$(get_active_container)

if [ -z "$ACTIVE_COLOR" ]; then
    # if no active container found, deploy 'blue'
    echo "🟦 Initial setup. Bringing up 'blue' containers..."
    docker compose --profile blue up -d
    wait_for_health "blue"
    install_dependencies "blue"
    update_nginx_config "blue"
    update_env_file "blue"
elif [ "$ACTIVE_COLOR" == "green" ]; then
    # if the active is 'green', deploy 'blue'
    PREVIOUS_COLOR="green"
    deploy "green" "blue"
elif [ "$ACTIVE_COLOR" == "blue" ]; then
    # if the active is 'blue', deploy 'green'
    PREVIOUS_COLOR="blue"
    deploy "blue" "green"
else
    # if the active is neither 'green' nor 'blue', reset to 'blue'
    echo "🚧 Unexpected CONTAINER_COLOR value. Resetting to 'blue'..."
    PREVIOUS_COLOR=""
    docker compose --profile blue up -d
    wait_for_health "blue"
    install_dependencies "blue"
    update_nginx_config "blue"
    update_env_file "blue"
fi

echo "🎉 Deployment successful!"

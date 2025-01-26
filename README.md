# Blue-Green Deployment in a Local Environment with Docker

## Introduction

Blue-Green Deployment is a deployment strategy designed to minimize downtime and risks during application updates. This approach involves running two separate environments, Blue and Green, where one serves traffic (the active environment) while the other is idle or undergoing updates. Once the updates are validated in the idle environment, traffic is switched seamlessly, ensuring stability and minimizing disruptions.

In this guide, we demonstrate how to implement Blue-Green Deployment using Docker in a local environment with Laravel as the example application. This approach is tailored for educational purposes, offering a hands-on way to grasp the fundamentals of Blue-Green Deployment.

## Why Docker for Blue-Green Deployment?

Docker provides an efficient way to isolate and simulate environments for Blue-Green Deployment in a local setup. Using Docker containers, you can create independent "Blue" and "Green" environments, test changes safely, and switch traffic between them.

This guide leverages Docker to:
- Simulate real-world deployment behavior.
- Visualize the Blue-Green Deployment process in an accessible way.
- Replicate health checks and traffic routing, similar to setups on platforms like AWS ECS or Kubernetes.

While there are other ways to test deployments locally, this method focuses on simplicity and clarity, allowing developers to understand the strategy without the complexity of managing cloud infrastructure.

## Why Test Locally?

Testing Blue-Green Deployment locally provides several benefits:
- Safe debugging: Identify issues in deployment scripts without impacting production.
- Replicating production workflows: Validate environment transitions, API integrations, and scheduled tasks.
- Downtime-free testing: Switch traffic seamlessly between containers, ensuring smooth user experiences.
- Hands-on learning: Gain a deep understanding of deployment strategies by observing their effects in real-time.

This local setup enables you to confidently refine deployment strategies before scaling them to production environments.

## Demonstration Setup

For this demonstration, the following components are used:
1. Nginx: Acts as the reverse proxy to route traffic to the active environment.
2. Health checks: Monitor container readiness and decide when to switch traffic.
3. Laravel: Example application to visualize environment transitions.

## The Vital Role of Health Checks in Blue-Green Deployment

One of the key components of this setup is the use of health checks. These checks continuously monitor the status of a container to determine if it is ready to handle traffic. Health checks are essential in Blue-Green Deployment, as they ensure stability and minimize risks during the transition between environments.

In this local setup, health checks play the following roles:
	1.	Simulating production behavior: Platforms like AWS ECS and Kubernetes rely heavily on health checks to determine if a service is operational. By defining health checks in our docker-compose.yml file, we replicate this behavior in a local environment, providing a close-to-real-world experience.
	2.	Automating deployment decisions: The deployment script uses health checks to decide whether traffic can be routed to the new environment. If a container fails its health checks, the script avoids switching traffic and triggers a rollback to maintain application availability.
	3.	Ensuring application readiness: Before switching traffic to a new environment, health checks validate that the new container is fully operational. This prevents downtime caused by incomplete deployments or application errors.

## Health Check Configuration

```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -f http://localhost || exit 1"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 5s
```

- test: Runs a command to check if the container is responding. In this case, it sends an HTTP request to the application and expects a successful response.
- interval: Sets the frequency of health check execution.
- timeout: Defines how long the health check can take before it’s considered a failure.
- retries: Specifies the number of consecutive failures before the container is marked as unhealthy.
- start_period: Allows a grace period for the container to fully initialize before health checks start.

## Visual Representation of Blue-Green Deployment

Here’s a simplified diagram of the Blue-Green Deployment process:

```plaintext
+-------------------+                   +--------------------+
|                   |                   |                    |
|   Active (Blue)   |  <--- Traffic --->|    Idle (Green)    |
|                   |                   |                    |
+-------------------+                   +--------------------+
         ↑                                    ↑
         |                                    |
   Updates & Tests                     Updates & Tests
         |                                    |
         ↓                                    ↓
+-------------------+                   +--------------------+
|   New Green       |                   |   New Blue         |
|   Deployment      |                   |   Deployment       |
+-------------------+                   +--------------------+
         |                                    |
   Health Checks Passed              Health Checks Passed
         ↓                                    ↓
+-------------------+                   +--------------------+
|   Idle (Blue)     |   <--- Traffic ---|   Active (Green)   |
+-------------------+                   +--------------------+
```

## Why Health Checks Are Critical

Health checks are the backbone of this Blue-Green Deployment strategy because they:
- Prevent downtime: Only containers that pass health checks receive traffic, ensuring users are always directed to a functional environment.
- Enable automated rollbacks: If a container fails its health checks, the script reverts to the previously active environment.
- Promote confidence: By validating the readiness of the new environment, health checks reduce the risk of deploying faulty updates.

## Components and Files

Here is an overview of the files used in this setup:

1. Deployment Script: Automates the creation, switching, and rollback of Blue-Green environments.

`abin/install.sh`
```sh
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
```


2. Nginx Configuration: Handles traffic routing to the active environment.

`nginx/default.conf`
```ini
server {
    listen 80;
    index index.php index.html;
    client_max_body_size 20M;
    root /var/www/html/public;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass app_backend;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
```

3. PHP-FPM Configuration: Manages PHP processes for Laravel.

`php/www.conf`
```ini
listen = 9000
user = www-data
group = www-data

[www]
pm = dynamic
pm.max_children = 20
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 15
```

4. Dockerfile: Sets up the Laravel environment with required dependencies.

`Dockerfile`
```Dockerfile
FROM php:8.2.0-fpm
WORKDIR /var/www/html
RUN apt-get update && apt-get install -y \
    curl \
    dos2unix \
    git \
    libonig-dev \
    libpng-dev \
    libxml2-dev \
    libzip-dev \
    unzip \
    zip \
    libfcgi0ldbl \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-install pdo_mysql mbstring exif pcntl bcmath gd zip \
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && mkdir -p /var/www/html/storage /var/www/html/bootstrap/cache && \
    chown -R :www-data ./bootstrap/cache && \
    mkdir -p storage && \
    cd storage/ && \
    mkdir -p logs && \
    mkdir -p app && \
    mkdir -p framework/sessions && \
    mkdir -p framework/views && \
    mkdir -p framework/cache && \
    chmod -R 775 framework logs app && \
    chown -R :www-data ./framework ./logs ./app && \
    git config --global --add safe.directory '*'

COPY ./scripts/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
CMD ["/usr/local/bin/start.sh"]
```

5. Docker Compose: Defines the Blue-Green containers, Nginx, and health check configurations.

`docker-compose.yml`
```yaml
services:
  blue:
    container_name: blue
    env_file:
      - .env
    profiles:
      - blue
    build:
      context: ./docker
      dockerfile: Dockerfile
    volumes:
      - ./:/var/www/html
      - ./docker/supervisor/supervisord.conf:/etc/supervisor/supervisord.conf
      - ./docker/php/www.conf:/usr/local/etc/php-fpm.d/www.conf
    healthcheck:
      test: ["CMD-SHELL", "SCRIPT_FILENAME=/var/www/html/public/index.php REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 5s

  green:
    container_name: green
    profiles:
      - green
    env_file:
      - .env
    build:
      context: ./docker
      dockerfile: Dockerfile
    volumes:
      - ./:/var/www/html
      - ./docker/supervisor/supervisord.conf:/etc/supervisor/supervisord.conf
      - ./docker/php/www.conf:/usr/local/etc/php-fpm.d/www.conf
    healthcheck:
      test: ["CMD-SHELL", "SCRIPT_FILENAME=/var/www/html/public/index.php REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 5s

  app:
    image: nginx:alpine
    container_name: app
    profiles:
      - blue
      - green
    ports:
      - "${PORT-80}:80"
    volumes:
      - ./:/var/www/html
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 5s
```

## Health Checks in Action

####  How It Works
1. When deploying updates:
    - A new environment (Blue or Green) is started.
	- Health checks validate the container’s readiness.
2. If health checks pass:
	- Traffic is routed to the new environment.
	- The old environment becomes idle, ready for future updates.
3. If health checks fail:
	- A rollback is triggered, and the active environment remains unchanged.

#### Automated Rollback Example

The deployment script ensures a rollback occurs when health checks fail. For example:
- Blue is active, and Green fails health checks.
- Traffic remains routed to Blue.
- The faulty Green container is removed, preserving application stability.

#### Examples:
- [🎥 Deployment demo](https://youtu.be/SKwZpRnhCkY): Visualizes the transition from Blue to Green.
- [🎥 Rollback demo](https://youtu.be/FZ9T3LmXBYs): Demonstrates how rollbacks maintain stability when an update fails.


## Conclusion
This guide demonstrates how to simulate and understand Blue-Green Deployment using Docker in a local environment. By leveraging health checks, traffic switching, and automated rollbacks, you can minimize downtime and ensure stability during deployments. While this approach is simplified, the concepts can easily extend to production-grade systems.

Use this setup to test and refine deployment strategies confidently before scaling to production.

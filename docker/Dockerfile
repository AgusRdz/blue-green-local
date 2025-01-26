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

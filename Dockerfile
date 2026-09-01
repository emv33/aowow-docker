FROM php:8.4-fpm

# Install system dependencies and Apache
RUN apt-get update && apt-get install -y \
    git \
    cmake \
    g++ \
    make \
    zlib1g-dev \
    libbz2-dev \
    libmariadb-dev \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libgmp-dev \
    libonig-dev \
    libffi-dev \
    ffmpeg \
    vorbis-tools \
    mariadb-client \
    ca-certificates \
    parallel \
    apache2 \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Build MPQExtractor from source (includes StormLib as submodule)
ARG MPQEXTRACTOR_GIT_URL=https://github.com/Sarjuuk/MPQExtractor.git
ARG MPQEXTRACTOR_GIT_BRANCH=master
WORKDIR /tmp
RUN git clone --recurse-submodules --branch ${MPQEXTRACTOR_GIT_BRANCH} ${MPQEXTRACTOR_GIT_URL} MPQExtractor \
    && cd MPQExtractor \
    && mkdir build && cd build \
    && cmake .. \
    && make \
    && cp bin/MPQExtractor /usr/local/bin/ \
    && cd /tmp && rm -rf MPQExtractor

# Install PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
    gd \
    mysqli \
    pdo_mysql \
    mbstring \
    intl \
    gmp \
    zip \
    ffi \
    && docker-php-ext-enable \
    gd \
    mysqli \
    mbstring \
    intl \
    gmp \
    zip \
    ffi

# Install Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Configure Apache
# Enable modules and copy custom virtual host config
RUN a2enmod rewrite proxy proxy_fcgi
COPY 000-default.conf /etc/apache2/sites-available/000-default.conf

# Clone AoWoW repository
ARG AOWOW_GIT_URL=https://github.com/Sarjuuk/aowow.git
ARG AOWOW_GIT_BRANCH=master
WORKDIR /var/www
RUN rm -rf html && \
    git clone --branch ${AOWOW_GIT_BRANCH} ${AOWOW_GIT_URL} html

# Set working directory
WORKDIR /var/www/html

# Install Composer dependencies
RUN composer install --no-dev

# Download TDB patches at build time
ARG TDB_PATCHES=1
ARG TDB_PATCHES_GIT_URL=https://github.com/TrinityCore/TrinityCore.git
ARG TDB_PATCHES_GIT_BRANCH=3.3.5
ARG TDB_PATCHES_GIT_PATH=sql/updates/world/3.3.5
RUN if [ "$TDB_PATCHES" = "1" ]; then \
        git clone --depth 1 --single-branch --branch "$TDB_PATCHES_GIT_BRANCH" \
            --filter=blob:none --sparse "$TDB_PATCHES_GIT_URL" /tmp/tc_patches \
        && cd /tmp/tc_patches \
        && git sparse-checkout set "$TDB_PATCHES_GIT_PATH" \
        && mkdir -p /usr/local/share/tdb-patches \
        && cp -r "$TDB_PATCHES_GIT_PATH"/. /usr/local/share/tdb-patches/ \
        && rm -rf /tmp/tc_patches; \
    fi

# Copy entrypoint script and config template
COPY docker-entrypoint.sh /usr/local/bin/
COPY config.php.template /usr/local/share/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Create necessary directories with correct permissions
RUN mkdir -p \
    cache \
    config \
    static/download \
    static/widgets \
    static/js \
    static/uploads \
    static/images/wow \
    datasets \
    setup/mpqdata \
    && chown -R www-data:www-data \
    cache \
    config \
    static \
    datasets \
    setup/mpqdata

# Silence parallel citation warning
RUN mkdir -p ~/.parallel && touch ~/.parallel/will-cite

EXPOSE 80

ENTRYPOINT ["docker-entrypoint.sh"]

# Start PHP-FPM in background (-D) and Apache in foreground
CMD ["sh", "-c", "php-fpm -D && apachectl -D FOREGROUND"]
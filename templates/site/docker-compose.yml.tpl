# Rendered by wpd from templates/site/docker-compose.yml.tpl. Tokens in double braces are filled in by `wpd new`.
name: {{Project}}

x-wp-env: &wp-env
  WORDPRESS_DB_HOST: db
  WORDPRESS_DB_USER: wp
  WORDPRESS_DB_PASSWORD: "{{DbPassword}}"
  WORDPRESS_DB_NAME: wordpress
  # wp-config.php (in the core volume) reads these at run time, so WP-CLI must get the same values as Apache.
  WORDPRESS_DEBUG: "1"
  WORDPRESS_CONFIG_EXTRA: |
    define('WP_HOME', '{{Url}}');
    define('WP_SITEURL', '{{Url}}');
    define('WP_ENVIRONMENT_TYPE', 'local');
    define('WP_DEBUG_LOG', true);
    define('WP_DEBUG_DISPLAY', false);
    define('DISABLE_WP_CRON', true);

# Core and uploads live in Docker volumes (fast); only code folders are bind-mounted so you can edit them.
x-wp-mounts: &wp-mounts
  - core:/var/www/html
  - uploads:/var/www/html/wp-content/uploads
  - ./wp-content/themes:/var/www/html/wp-content/themes
  - ./wp-content/plugins:/var/www/html/wp-content/plugins
  - ./wp-content/mu-plugins:/var/www/html/wp-content/mu-plugins
  - ./php.ini:/usr/local/etc/php/conf.d/wpd.ini:ro

services:
  db:
    image: mariadb:10.11
    restart: unless-stopped
    environment:
      MARIADB_RANDOM_ROOT_PASSWORD: "1"
      MARIADB_DATABASE: wordpress
      MARIADB_USER: wp
      MARIADB_PASSWORD: "{{DbPassword}}"
    volumes:
      - dbdata:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 3s
      timeout: 5s
      retries: 40
      start_period: 5s

  wordpress:
    image: wordpress:php{{Php}}-apache
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment: *wp-env
    volumes: *wp-mounts
    networks: [default, web]
    labels:
      - traefik.enable=true
      - traefik.docker.network={{Network}}
      - "traefik.http.routers.{{Project}}.rule=Host(`{{Name}}.{{Tld}}`)"
      - traefik.http.routers.{{Project}}.entrypoints=websecure
      - traefik.http.routers.{{Project}}.tls=true
      - "traefik.http.routers.{{Project}}-http.rule=Host(`{{Name}}.{{Tld}}`)"
      - traefik.http.routers.{{Project}}-http.entrypoints=web
      - traefik.http.routers.{{Project}}-http.middlewares={{Project}}-https
      - traefik.http.middlewares.{{Project}}-https.redirectscheme.scheme=https
      - traefik.http.middlewares.{{Project}}-https.redirectscheme.port={{HttpsPort}}
      - traefik.http.services.{{Project}}.loadbalancer.server.port=80

  # Run on demand: docker compose run --rm wpcli wp <command>
  wpcli:
    image: wordpress:cli-php{{Php}}
    profiles: [tools]
    user: "33:33"
    working_dir: /var/www/html
    depends_on:
      db:
        condition: service_healthy
    environment: *wp-env
    volumes: *wp-mounts
    networks: [default]

  mailpit:
    image: axllent/mailpit:latest
    restart: unless-stopped
    networks: [default, web]
    labels:
      - traefik.enable=true
      - traefik.docker.network={{Network}}
      - "traefik.http.routers.{{Project}}-mail.rule=Host(`mail.{{Name}}.{{Tld}}`)"
      - traefik.http.routers.{{Project}}-mail.entrypoints=websecure
      - traefik.http.routers.{{Project}}-mail.tls=true
      - traefik.http.services.{{Project}}-mail.loadbalancer.server.port=8025

volumes:
  core:
  uploads:
  dbdata:

networks:
  web:
    external: true
    name: {{Network}}

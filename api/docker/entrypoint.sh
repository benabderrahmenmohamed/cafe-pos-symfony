#!/bin/sh
# What this server needs before it can answer anything: keys to sign tokens with, and a schema.
set -e

cd /var/www/html

# What this container was told, where Symfony will actually look for it.
#
# Symfony reads its configuration from $_ENV and $_SERVER, never getenv(), and not every SAPI fills
# those from the process environment - the PHP built-in server fills neither. Writing them into
# .env.local, which every SAPI reads the same way, is what makes `docker run -e DATABASE_URL=…`
# mean what it says. Single quotes because a value may hold a `$`: CORS_ALLOW_ORIGIN is a regex.
: > .env.local
for name in APP_ENV APP_SECRET DATABASE_URL DATABASE_ADMIN_URL JWT_SECRET_KEY JWT_PUBLIC_KEY \
            JWT_PASSPHRASE CORS_ALLOW_ORIGIN DEFAULT_URI; do
    value=$(printenv "$name" || true)
    if [ -n "$value" ]; then
        printf "%s='%s'\n" "$name" "$value" >> .env.local
    fi
done

# The keys that sign the tokens. A deployment mounts its own at config/jwt; keys made here live and
# die with the container, so every new container signs every device out and two replicas reject each
# other's tokens. Fine for a demo, and said plainly in api/README.md for anything else.
if [ ! -f config/jwt/private.pem ]; then
    echo "No keypair is mounted. Making one that lasts as long as this container."
    php bin/console lexik:jwt:generate-keypair --no-interaction
fi

# The database is usually starting at the same moment this is, so the migration is the wait: it is
# the first thing that needs the database anyway, and retrying it beats guessing how long to sleep.
if [ "${MIGRATE_ON_START:-1}" = "1" ]; then
    tries=0
    until php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration; do
        tries=$((tries + 1))
        if [ "$tries" -ge 10 ]; then
            echo "The database did not answer after $tries tries. Giving up." >&2
            exit 1
        fi
        echo "Waiting for the database ($tries)..."
        sleep 3
    done
fi

# The demo café - its people, its room and its menu, from App\Demo\DemoSeeder. It is refused on a
# database that already has a café, so starting this container again changes nothing.
if [ "${SEED_DEMO:-0}" = "1" ]; then
    php bin/console app:seed-demo --no-interaction
fi

# Everything above ran as root, and Apache does not: the cache those commands warmed and the keys
# they may have written have to belong to the user that serves the café.
chown -R www-data:www-data var config/jwt .env.local

exec "$@"

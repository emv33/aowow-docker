#!/bin/bash
set -e

echo "============================================"
echo "AoWoW Installation Setup"
echo "============================================"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_error() {
    echo -e "${RED}[Error]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[Success]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[Info]${NC} $1"
}

# Function to sort MPQ files
# 1. Sorts alphabetically
# 2. Ensures files with hyphens come AFTER the base file (common.MPQ < common-2.MPQ)
#    It does this by temporarily replacing '.MPQ' with '#MPQ' (ASCII 35) which sorts before '-MPQ' (ASCII 45)
sort_mpqs() {
    sed 's/\.MPQ$/#MPQ/' | LC_COLLATE=C sort | sed 's/#MPQ$/.MPQ/'
}

# Check if WoW client exists
echo ""
print_info "Checking for World of Warcraft client files..."
if [ ! -d "/wow-client" ] || [ -z "$(ls -A /wow-client)" ]; then
    print_error "World of Warcraft client directory not found or empty!"
    print_error "Please mount your WoW client directory to /wow-client"
    print_error "Example: -v /path/to/wow:/wow-client:ro"
    exit 1
fi

# Check for WoW.exe or Wow.exe
if [ ! -f "/wow-client/WoW.exe" ] && [ ! -f "/wow-client/Wow.exe" ] && [ ! -f "/wow-client/wow.exe" ]; then
    print_error "WoW.exe not found in client directory!"
    print_error "Please ensure you've mounted the correct WoW 3.3.5a client directory"
    exit 1
fi
print_success "World of Warcraft client found"

# Validate AOWOW_ACC_ALLOW_REGISTER
if [[ "$AOWOW_ACC_ALLOW_REGISTER" != "0" && "$AOWOW_ACC_ALLOW_REGISTER" != "1" ]]; then
    print_error "AOWOW_ACC_ALLOW_REGISTER must be 0 or 1"
    exit 1
fi

# Validate AOWOW_FORCE_SSL
# Treat empty as 0
if [ -z "$AOWOW_FORCE_SSL" ]; then
    AOWOW_FORCE_SSL=0
fi

if [[ "$AOWOW_FORCE_SSL" != "0" && "$AOWOW_FORCE_SSL" != "1" ]]; then
    print_error "AOWOW_FORCE_SSL must be 0 or 1"
    exit 1
fi

# Validate and check locales
echo ""
print_info "Validating WoW locales..."
# Read as space-separated list
read -ra LOCALES <<< "$WOW_LOCALE"
VALID_LOCALES=()

for locale in "${LOCALES[@]}"; do
    # Trim whitespace
    locale=$(echo "$locale" | xargs)

    # Check if locale directory exists in WoW client
    if [ -d "/wow-client/Data/$locale" ]; then
        print_success "Locale '$locale' found in WoW client"
        VALID_LOCALES+=("$locale")
    else
        print_error "Locale '$locale' not found in /wow-client/Data/"
        print_error "Available locales in client:"
        ls -d /wow-client/Data/*/ 2>/dev/null | xargs -n1 basename || print_error "  No locale directories found"
        exit 1
    fi
done

if [ ${#VALID_LOCALES[@]} -eq 0 ]; then
    print_error "No valid locales found!"
    exit 1
fi

print_success "All specified locales validated: ${VALID_LOCALES[*]}"

# Check if TDB SQL file exists
echo ""
print_info "Checking for TrinityCore Database (TDB) SQL file..."
if [ ! -f "/tdb/TDB.sql" ]; then
    print_error "TDB SQL file not found at /tdb/TDB.sql!"
    print_error "Please mount your TDB_full_world_335.21101_2021_10_17.sql file"
    print_error "Example: -v /path/to/TDB.sql:/tdb/TDB.sql:ro"
    exit 1
fi
print_success "TDB SQL file found"

# Wait for database to be ready
echo ""
print_info "Waiting for database to be ready..."
until mysql -h"$AOWOW_DB_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" --skip-ssl -e "SELECT 1" >/dev/null 2>&1; do
    echo "Database is unavailable - sleeping"
    sleep 2
done
print_success "Database is ready"

# Create databases and users if they don't exist
echo ""
print_info "Setting up databases and users..."

# Create AoWoW database and user
mysql -h"$AOWOW_DB_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" --skip-ssl <<EOF
CREATE DATABASE IF NOT EXISTS \`$AOWOW_DB_DATABASE\`;
CREATE USER IF NOT EXISTS '$AOWOW_DB_USER'@'%' IDENTIFIED BY '$AOWOW_DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$AOWOW_DB_DATABASE\`.* TO '$AOWOW_DB_USER'@'%';
EOF

# Create World database and user
mysql -h"$WORLD_DB_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" --skip-ssl <<EOF
CREATE DATABASE IF NOT EXISTS \`$WORLD_DB_DATABASE\`;
CREATE USER IF NOT EXISTS '$WORLD_DB_USER'@'%' IDENTIFIED BY '$WORLD_DB_PASSWORD';
GRANT SELECT ON \`$WORLD_DB_DATABASE\`.* TO '$WORLD_DB_USER'@'%';
EOF

# Create Auth database and user
mysql -h"$AUTH_DB_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" --skip-ssl <<EOF
CREATE DATABASE IF NOT EXISTS \`$AUTH_DB_DATABASE\`;
CREATE USER IF NOT EXISTS '$AUTH_DB_USER'@'%' IDENTIFIED BY '$AUTH_DB_PASSWORD';
GRANT SELECT ON \`$AUTH_DB_DATABASE\`.* TO '$AUTH_DB_USER'@'%';
EOF

# Create Characters database and user
mysql -h"$CHARACTERS_DB_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" --skip-ssl <<EOF
CREATE DATABASE IF NOT EXISTS \`$CHARACTERS_DB_DATABASE\`;
CREATE USER IF NOT EXISTS '$CHARACTERS_DB_USER'@'%' IDENTIFIED BY '$CHARACTERS_DB_PASSWORD';
GRANT SELECT ON \`$CHARACTERS_DB_DATABASE\`.* TO '$CHARACTERS_DB_USER'@'%';
FLUSH PRIVILEGES;
EOF

print_success "Databases and users created"

# Check if AoWoW database initialization is needed
echo ""
print_info "Checking AoWoW database initialization status..."
DB_TABLES=$(mysql -h"$AOWOW_DB_HOST" -u"$AOWOW_DB_USER" -p"$AOWOW_DB_PASSWORD" --skip-ssl "$AOWOW_DB_DATABASE" -e "SHOW TABLES;" 2>/dev/null | wc -l)

if [ "$DB_TABLES" -lt 5 ]; then
    print_info "AoWoW database appears empty. Running initialization..."

    # Import all SQL files in the setup directory
    for sql_file in /var/www/html/setup/sql/*.sql; do
        if [ -f "$sql_file" ]; then
            print_info "Importing $(basename $sql_file)..."
            mysql -h"$AOWOW_DB_HOST" -u"$AOWOW_DB_USER" -p"$AOWOW_DB_PASSWORD" --skip-ssl "$AOWOW_DB_DATABASE" < "$sql_file"
        fi
    done

    print_info "Applying initial configuration to AoWoW database..."

    # Base Configuration & Global Settings
    mysql -h"$AOWOW_DB_HOST" -u"$AOWOW_DB_USER" -p"$AOWOW_DB_PASSWORD" --skip-ssl "$AOWOW_DB_DATABASE" <<EOF
UPDATE aowow_config SET value='$SITE_HOST' WHERE \`key\`='site_host';
UPDATE aowow_config SET value='$STATIC_HOST' WHERE \`key\`='static_host';
UPDATE aowow_config SET value='$AOWOW_ACC_ALLOW_REGISTER' WHERE \`key\`='acc_allow_register';
UPDATE aowow_config SET value='$AOWOW_FORCE_SSL' WHERE \`key\`='force_ssl';
UPDATE aowow_config SET value='$AOWOW_SQL_LIMIT_DEFAULT' WHERE \`key\`='sql_limit_default';
UPDATE aowow_config SET value='$AOWOW_SQL_LIMIT_SEARCH' WHERE \`key\`='sql_limit_search';
UPDATE aowow_config SET value='$AOWOW_MEMORY_LIMIT' WHERE \`key\`='memory_limit';
UPDATE aowow_config SET value='1' WHERE \`key\`='maintenance';
UPDATE aowow_config SET value='3' WHERE \`key\`='debug';
EOF

    # Calculate Locale Bitmask
    print_info "Configuring locales..."
    LOCALE_BITMASK=0

    for locale in "${VALID_LOCALES[@]}"; do
        BIT_SHIFT=0
        case "$locale" in
            "enGB"|"enUS")   BIT_SHIFT=0 ;;
            "koKR")          BIT_SHIFT=1 ;;
            "frFR")          BIT_SHIFT=2 ;;
            "deDE")          BIT_SHIFT=3 ;;
            "zhCN"|"enCN")   BIT_SHIFT=4 ;;
            "zhTW"|"enTW")   BIT_SHIFT=5 ;;
            "esES")          BIT_SHIFT=6 ;;
            "esMX")          BIT_SHIFT=7 ;;
            "ruRU")          BIT_SHIFT=8 ;;
            "jaJP")          BIT_SHIFT=9 ;;
            "ptPT"|"ptBR")   BIT_SHIFT=10 ;;
            "itIT")          BIT_SHIFT=11 ;;
            *)
                print_error "Configuration failed: WOW_LOCALE contains unknown locale '$locale'"
                exit 1
                ;;
        esac

        # Calculate bit value and add to mask using bitwise OR
        LOCALE_VAL=$((1 << BIT_SHIFT))
        LOCALE_BITMASK=$((LOCALE_BITMASK | LOCALE_VAL))
        print_info "  - Added locale $locale (Bit: $BIT_SHIFT, Value: $LOCALE_VAL)"
    done

    print_info "  - Setting final locale bitmask: $LOCALE_BITMASK"
    mysql -h"$AOWOW_DB_HOST" -u"$AOWOW_DB_USER" -p"$AOWOW_DB_PASSWORD" --skip-ssl "$AOWOW_DB_DATABASE" \
        -e "UPDATE aowow_config SET value='$LOCALE_BITMASK' WHERE \`key\`='locales';"

    print_success "AoWoW database structure initialized and configured"
else
    print_success "AoWoW database already initialized"
fi

# Check if TDB needs to be imported
echo ""
print_info "Checking World database (TDB) status..."
WORLD_TABLES=$(mysql -h"$WORLD_DB_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" --skip-ssl "$WORLD_DB_DATABASE" -e "SHOW TABLES;" 2>/dev/null | wc -l)

if [ "$WORLD_TABLES" -lt 5 ]; then
    print_info "World database appears empty. Importing TDB..."
    print_info "This will take several minutes..."
    mysql -h"$WORLD_DB_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" --skip-ssl "$WORLD_DB_DATABASE" < /tdb/TDB.sql
    print_success "TDB imported successfully"
else
    print_success "World database already populated"
fi

# Extract MPQ files if not already done
echo ""
print_info "Checking MPQ extraction status..."

ALL_LOCALES_EXTRACTED=true
for locale in "${VALID_LOCALES[@]}"; do
    if [ ! -d "/var/www/html/setup/mpqdata/$locale" ] || [ -z "$(ls -A /var/www/html/setup/mpqdata/$locale 2>/dev/null)" ]; then
        ALL_LOCALES_EXTRACTED=false
        break
    fi
done

# Determine number of threads
THREADS=${AOWOW_CONVERSION_THREADS:-0}
if [ "$THREADS" -eq 0 ]; then
    THREADS=$(nproc)
fi

if [ "$ALL_LOCALES_EXTRACTED" = false ]; then
    print_info "MPQ files need extraction. Starting optimized process..."

    # ---------------------------------------------------------
    # 1. Extract Base MPQs and First Locale Sound
    # ---------------------------------------------------------
    BASE_DIR="/var/www/html/setup/mpqdata/base"
    mkdir -p "$BASE_DIR"

    # 1a. Generic/Base MPQs
    BASE_MPQS=$(find "/wow-client/Data" -maxdepth 1 -name "*.MPQ" | sort_mpqs)
    BASE_MPQS=$(echo "$BASE_MPQS" | sed '/^$/d')

    if [ -z "$BASE_MPQS" ]; then
        print_error "No base MPQ files found in /wow-client/Data"
        exit 1
    fi

    # Only extract Sound from base MPQs
    COMMON_PATHS=("Sound")

    print_info "Phase 1a: Extracting base MPQs to $BASE_DIR..."

    echo "$BASE_MPQS" | while read -r mpq; do
        MPQ_NAME=$(basename "$mpq")
        print_info "  Processing base MPQ: $MPQ_NAME"
        for path in "${COMMON_PATHS[@]}"; do
            print_info "    Extracting: $path"
            # Using wildcard for directory extraction
            MPQExtractor -e "$path/*" -o "$BASE_DIR" -f "$mpq" || true
        done
    done

    # 1b. First Locale Sound (Treating as Base)
    FIRST_LOCALE="${VALID_LOCALES[0]}"
    print_info "Phase 1b: Extracting sound from first locale ($FIRST_LOCALE) to base..."

    FIRST_LOCALE_MPQS=$(find "/wow-client/Data/$FIRST_LOCALE" -name "*.MPQ" | sort_mpqs)
    FIRST_LOCALE_MPQS=$(echo "$FIRST_LOCALE_MPQS" | sed '/^$/d')

    echo "$FIRST_LOCALE_MPQS" | while read -r mpq; do
        MPQ_NAME=$(basename "$mpq")
        print_info "  Processing first locale MPQ for sound: $MPQ_NAME"
        # Extract ONLY Sound
        print_info "    Extracting: Sound"
        MPQExtractor -e "Sound/*" -o "$BASE_DIR" -f "$mpq" || true
    done

    print_success "Base extraction complete."

    # ---------------------------------------------------------
    # 2. Process Base Audio (In-Place)
    # ---------------------------------------------------------
    print_info "Phase 2: Processing base audio files..."

    if [ -d "$BASE_DIR/Sound" ]; then
        pushd "$BASE_DIR/Sound" >/dev/null

        # Convert WAV -> OGG
        WAV_COUNT=$(find . -name "*.wav" | wc -l)
        if [ "$WAV_COUNT" -gt 0 ]; then
            print_info "  Converting $WAV_COUNT base WAV files..."
            find . -name "*.wav" -print0 | \
                parallel -0 -j "$THREADS" \
                "ffmpeg -hide_banner -loglevel error -y -i {} -acodec libvorbis -q:a 4 -f ogg {}_ >/dev/null && rm {} && echo \"[{#}/$WAV_COUNT] Converted base: {}_\"" || true
        fi

        # Rebuild MP3 -> MP3
        MP3_COUNT=$(find . -name "*.mp3" | wc -l)
        if [ "$MP3_COUNT" -gt 0 ]; then
            print_info "  Rebuilding $MP3_COUNT base MP3 files..."
            find . -name "*.mp3" -print0 | \
                parallel -0 -j "$THREADS" \
                "ffmpeg -hide_banner -loglevel error -y -i {} -c copy -f mp3 {}_ >/dev/null && rm {} && echo \"[{#}/$MP3_COUNT] Copied base: {}_\"" || true
        fi

        popd >/dev/null
    fi
    print_success "Base audio processing complete."

    # ---------------------------------------------------------
    # 3-4. Locale Processing Loop
    # ---------------------------------------------------------

    # Sound is excluded here; base audio files are used via hardlinks.
    SPECIFIC_PATHS=(
        "DBFilesClient"
        "Interface"
    )

    for locale in "${VALID_LOCALES[@]}"; do
        LOCALE_DIR="/var/www/html/setup/mpqdata/$locale"
        print_info "Starting processing for locale: $locale"
        mkdir -p "$LOCALE_DIR"

        # 3. Recreate Tree (Hardlinks)
        # cp -al recursively creates hardlinks of the directory structure
        print_info "  Phase 3: Linking base files to locale folder..."
        cp -al "$BASE_DIR/." "$LOCALE_DIR/"

        # 4. Extract Locale MPQs
        print_info "  Phase 4: Extracting locale-specific MPQs..."

        # Create a temporary directory for extraction
        TEMP_DIR="/var/www/html/setup/mpqdata/temp_extract_$locale"
        mkdir -p "$TEMP_DIR"
        print_info "    Extracting to temporary directory: $TEMP_DIR"

        LOC_DIR="/wow-client/Data/$locale"
        LOCALE_MPQS=""
        LOCALE_MPQS+="$(find "$LOC_DIR" -maxdepth 1 -name "locale-$locale*.MPQ" | sort_mpqs)"$'\n'
        LOCALE_MPQS+="$(find "$LOC_DIR" -maxdepth 1 -name "speech-$locale*.MPQ" | sort_mpqs)"$'\n'
        LOCALE_MPQS+="$(find "$LOC_DIR" -maxdepth 1 -name "expansion-locale-$locale*.MPQ" | sort_mpqs)"$'\n'
        LOCALE_MPQS+="$(find "$LOC_DIR" -maxdepth 1 -name "expansion-speech-$locale*.MPQ" | sort_mpqs)"$'\n'
        LOCALE_MPQS+="$(find "$LOC_DIR" -maxdepth 1 -name "lichking-locale-$locale*.MPQ" | sort_mpqs)"$'\n'
        LOCALE_MPQS+="$(find "$LOC_DIR" -maxdepth 1 -name "lichking-speech-$locale*.MPQ" | sort_mpqs)"$'\n'
        LOCALE_MPQS+="$(find "$LOC_DIR" -maxdepth 1 -name "patch-$locale*.MPQ" | sort_mpqs)"$'\n'
        # Others
        LOCALE_MPQS+="$(find "$LOC_DIR" -maxdepth 1 -name "*.MPQ" \
            ! -name "locale-$locale*.MPQ" \
            ! -name "speech-$locale*.MPQ" \
            ! -name "expansion-locale-$locale*.MPQ" \
            ! -name "expansion-speech-$locale*.MPQ" \
            ! -name "lichking-locale-$locale*.MPQ" \
            ! -name "lichking-speech-$locale*.MPQ" \
            ! -name "patch-$locale*.MPQ" | sort_mpqs)"

        LOCALE_MPQS=$(echo "$LOCALE_MPQS" | sed '/^$/d')

        echo "$LOCALE_MPQS" | while read -r mpq; do
            MPQ_NAME=$(basename "$mpq")
            print_info "    Processing locale MPQ: $MPQ_NAME"
            for path in "${SPECIFIC_PATHS[@]}"; do
                # Determine wildcard usage
                if [[ "$path" == *".lua" ]]; then
                    SEARCH_PATTERN="$path"
                else
                    SEARCH_PATTERN="$path/*"
                fi
                MPQExtractor -e "$SEARCH_PATTERN" -o "$TEMP_DIR" -f "$mpq" || true
            done
        done

        # Clean 0-byte files from temp
        print_info "    Cleaning 0-byte files..."
        find "$TEMP_DIR" -type f -size 0 -delete

        # Merge temp to locale, breaking hardlinks with --remove-destination
        print_info "    Merging files to locale directory..."
        if [ -n "$(ls -A $TEMP_DIR 2>/dev/null)" ]; then
            cp -r --remove-destination "$TEMP_DIR/"* "$LOCALE_DIR/"
        fi

        # Cleanup temp dir
        rm -rf "$TEMP_DIR"

        # 5. Process Locale-Specific Audio (SKIPPED)
        # Sound is not extracted in step 4; all audio comes from the hardlinked base folder.

        print_success "Locale $locale completed."
    done

    # Remove Base Directory after all operations
    print_info "Cleaning up base directory..."
    rm -rf "$BASE_DIR"

    print_success "All MPQ operations complete"
else
    print_success "MPQ files already extracted for all locales"
fi

# Set proper permissions
echo ""
print_info "Setting proper file permissions..."
chown -R www-data:www-data /var/www/html/cache
chown -R www-data:www-data /var/www/html/config
chown -R www-data:www-data /var/www/html/static
chown -R www-data:www-data /var/www/html/datasets
chown -R www-data:www-data /var/www/html/setup/mpqdata
print_success "Permissions set"

# Generate config.php from template
echo ""
print_info "Generating config.php..."
if [ ! -f "/var/www/html/config/config.php" ]; then
    # Read template and substitute variables
    sed -e "s|%%AOWOW_DB_HOST%%|$AOWOW_DB_HOST|g" \
        -e "s|%%AOWOW_DB_USER%%|$AOWOW_DB_USER|g" \
        -e "s|%%AOWOW_DB_PASSWORD%%|$AOWOW_DB_PASSWORD|g" \
        -e "s|%%AOWOW_DB_DATABASE%%|$AOWOW_DB_DATABASE|g" \
        -e "s|%%WORLD_DB_HOST%%|$WORLD_DB_HOST|g" \
        -e "s|%%WORLD_DB_USER%%|$WORLD_DB_USER|g" \
        -e "s|%%WORLD_DB_PASSWORD%%|$WORLD_DB_PASSWORD|g" \
        -e "s|%%WORLD_DB_DATABASE%%|$WORLD_DB_DATABASE|g" \
        -e "s|%%AUTH_DB_HOST%%|$AUTH_DB_HOST|g" \
        -e "s|%%AUTH_DB_USER%%|$AUTH_DB_USER|g" \
        -e "s|%%AUTH_DB_PASSWORD%%|$AUTH_DB_PASSWORD|g" \
        -e "s|%%AUTH_DB_DATABASE%%|$AUTH_DB_DATABASE|g" \
        -e "s|%%CHARACTERS_DB_HOST%%|$CHARACTERS_DB_HOST|g" \
        -e "s|%%CHARACTERS_DB_USER%%|$CHARACTERS_DB_USER|g" \
        -e "s|%%CHARACTERS_DB_PASSWORD%%|$CHARACTERS_DB_PASSWORD|g" \
        -e "s|%%CHARACTERS_DB_DATABASE%%|$CHARACTERS_DB_DATABASE|g" \
        /usr/local/share/config.php.template > /var/www/html/config/config.php

    chown www-data:www-data /var/www/html/config/config.php
    print_success "config.php generated"
else
    print_success "config.php already exists"
fi

# Run AoWoW setup if needed
echo ""
if [ ! -f "/var/www/html/config/.setup_complete" ]; then
    print_info "Initial AoWoW setup..."
    print_info "You may need to run 'php aowow --setup' manually inside the container"
    print_info "Use: docker exec -it aowow_web php aowow --setup"
else
    print_success "AoWoW already configured"
fi

echo ""
echo "============================================"
print_success "Setup validation complete!"
echo "============================================"

# Final Configuration cleanup (Maintenance Mode OFF, Debug OFF)
print_info "Finalizing configuration..."
mysql -h"$AOWOW_DB_HOST" -u"$AOWOW_DB_USER" -p"$AOWOW_DB_PASSWORD" --skip-ssl "$AOWOW_DB_DATABASE" <<EOF
UPDATE aowow_config SET value='0' WHERE \`key\`='maintenance';
UPDATE aowow_config SET value='0' WHERE \`key\`='debug';
EOF
print_success "Maintenance mode disabled and debug level set to 0."

print_info "Databases configured:"
print_info "  - AoWoW:      $AOWOW_DB_HOST/$AOWOW_DB_DATABASE"
print_info "  - World:      $WORLD_DB_HOST/$WORLD_DB_DATABASE"
print_info "  - Auth:       $AUTH_DB_HOST/$AUTH_DB_DATABASE"
print_info "  - Characters: $CHARACTERS_DB_HOST/$CHARACTERS_DB_DATABASE"
print_info ""
print_info "Web interface will be available on port ${WEB_PORT:-8080}"
print_info ""
print_info "Next steps:"
print_info "1. Run setup: docker exec -it aowow_web php aowow --setup"
print_info "2. Post-setup cleanup (optional):"
print_info "   docker exec -it aowow_web rm -rf setup/mpqdata"
print_info "3. Access the web interface at http://localhost:${WEB_PORT:-8080}"
echo "============================================"
echo ""

# Execute the main container command
exec "$@"
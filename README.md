# AoWoW Docker Stack

Automated deployment for AoWoW (WotLK 3.3.5a). Handles database creation, MPQ extraction, and audio conversion.

## Prerequisites

*   World of Warcraft 3.3.5a Client
*   TrinityCore TDB 3.3.5a SQL file (e.g., `TDB_full_world_335.21101_2021_10_17.sql`)
*   Docker & Docker Compose

## Setup

1.  **Configure Environment**
    ```bash
    cp .env.example .env
    ```
    Edit `.env`. Essential variables:
    *   `WOW_CLIENT_PATH`: Path to WoW folder.
    *   `TDB_SQL_PATH`: Path to TDB `.sql` file.
    *   `WOW_LOCALE`: Space-separated list (e.g., `enUS deDE`).

2.  **Start Containers**
    ```bash
    docker compose up -d --build
    ```

3.  **Wait for Extraction**
    The initialization process extracts MPQs and converts audio. **This takes a significant amount of time.**
    Monitor progress:
    ```bash
    docker compose logs -f web
    ```

## Finalization

Once the logs show `Setup validation complete!`:

1.  **Run AoWoW Installer**
    ```bash
    docker exec -it aowow_web php aowow --setup
    ```

2.  **Cleanup (Free Disk Space)**
    ```bash
    docker exec -it aowow_web rm -rf setup/mpqdata
    ```

3.  **Access**
    Visit `http://localhost:8080` (or configured `WEB_PORT`).
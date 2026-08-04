#!/usr/bin/env bash
set -Eeuo pipefail

readonly REMOTE_PATH="oracle-mc:minecraft-bucket"
readonly LOCAL_DIR="$RUNNER_TEMP/minecraft"
readonly BACKUP_INTERVAL=900
readonly PAPER_VERSION="${PAPER_VERSION:-26.2}"
readonly PAPER_JAR="paper.jar"
readonly PAPER_API="https://fill.papermc.io/v3/projects/paper/versions/$PAPER_VERSION/builds"
readonly PAPER_USER_AGENT="mc-angel/1.0 (https://github.com/${GITHUB_REPOSITORY:-mc-angel})"
readonly GEYSER_JAR="plugins/Geyser-Spigot.jar"
readonly FLOODGATE_JAR="plugins/floodgate-spigot.jar"
readonly AUTHME_VERSION="6.0.0"
readonly AUTHME_JAR="plugins/AuthMe-$AUTHME_VERSION-Paper.jar"
readonly AUTHME_CONFIG="plugins/AuthMe/config.yml"
readonly PROJECT_DIR="${GITHUB_WORKSPACE:-$PWD}"

SERVER_PID=""
PLAYIT_PID=""
CONSOLE_FD_OPEN=false
STATE_LOADED=false

sync_files() {
    rclone sync "$LOCAL_DIR/" "$REMOTE_PATH/" \
        --exclude "server.stdin" \
        --exclude "*.tmp" \
        --exclude "plugins/AuthMe/config.yml*" \
        --fast-list \
        --transfers=8 \
        --checkers=8
}

set_server_property() {
    local key="$1"
    local value="$2"

    touch server.properties
    if grep -Eq "^${key}=" server.properties; then
        sed -i "s/^${key}=.*/${key}=${value}/" server.properties
    else
        printf '%s=%s\n' "$key" "$value" >>server.properties
    fi
}

download_paper() {
    local builds_response paper_url paper_sha256 current_sha256

    echo "Buscando la compilacion estable mas reciente de Paper $PAPER_VERSION..."
    builds_response="$(curl --fail --silent --show-error --location \
        --header "User-Agent: $PAPER_USER_AGENT" \
        "$PAPER_API")"
    paper_url="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads."server:default".url) // empty' \
        <<<"$builds_response")"
    paper_sha256="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads."server:default".checksums.sha256) // empty' \
        <<<"$builds_response")"

    [[ -n "$paper_url" ]] || {
        echo "No existe una compilacion estable de Paper $PAPER_VERSION."
        exit 1
    }

    current_sha256="$(sha256sum "$PAPER_JAR" 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$paper_sha256" ]] && [[ "$current_sha256" == "$paper_sha256" ]]; then
        echo "Paper $PAPER_VERSION ya esta actualizado."
        return 0
    fi

    curl --fail --silent --show-error --location --retry 3 \
        --header "User-Agent: $PAPER_USER_AGENT" \
        --output "$PAPER_JAR.tmp" \
        "$paper_url"
    if [[ -n "$paper_sha256" ]]; then
        echo "$paper_sha256  $PAPER_JAR.tmp" | sha256sum --check
    fi
    mv -f "$PAPER_JAR.tmp" "$PAPER_JAR"
    echo "Paper $PAPER_VERSION actualizado."
    FRESH_INSTALL=true
    return 0
}

download_crossplay_plugins() {
    local changed=false
    mkdir -p plugins

    echo "Descargando la version mas reciente de Geyser para Bedrock..."
    curl --fail --silent --show-error --location --retry 3 \
        --output "$GEYSER_JAR.tmp" \
        "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot"
    if [[ ! -f "$GEYSER_JAR" ]] || ! cmp -s "$GEYSER_JAR.tmp" "$GEYSER_JAR"; then
        mv -f "$GEYSER_JAR.tmp" "$GEYSER_JAR"
        changed=true
    else
        rm -f "$GEYSER_JAR.tmp"
    fi

    echo "Descargando la version mas reciente de Floodgate..."
    curl --fail --silent --show-error --location --retry 3 \
        --output "$FLOODGATE_JAR.tmp" \
        "https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot"
    if [[ ! -f "$FLOODGATE_JAR" ]] || ! cmp -s "$FLOODGATE_JAR.tmp" "$FLOODGATE_JAR"; then
        mv -f "$FLOODGATE_JAR.tmp" "$FLOODGATE_JAR"
        changed=true
    else
        rm -f "$FLOODGATE_JAR.tmp"
    fi

    if [[ "$changed" == true ]]; then
        FRESH_INSTALL=true
    fi
}

download_and_configure_authme() {
    local release_data authme_url authme_digest current_sha256

    mkdir -p plugins/AuthMe
    echo "Descargando AuthMe $AUTHME_VERSION para Paper..."
    release_data="$(curl --fail --silent --show-error --location --retry 3 \
        --header "User-Agent: $PAPER_USER_AGENT" \
        "https://api.github.com/repos/AuthMe/AuthMeReloaded/releases/tags/$AUTHME_VERSION")"
    authme_url="$(jq -r --arg name "AuthMe-$AUTHME_VERSION-Paper.jar" \
        '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_data")"
    authme_digest="$(jq -r --arg name "AuthMe-$AUTHME_VERSION-Paper.jar" \
        '.assets[] | select(.name == $name) | (.digest // "")' <<<"$release_data")"

    [[ -n "$authme_url" ]] || {
        echo "No se encontro el JAR de Paper en la version AuthMe $AUTHME_VERSION."
        exit 1
    }

    curl --fail --silent --show-error --location --retry 3 \
        --output "$AUTHME_JAR.tmp" \
        "$authme_url"
    if [[ "$authme_digest" == sha256:* ]]; then
        echo "${authme_digest#sha256:}  $AUTHME_JAR.tmp" | sha256sum --check
    fi

    current_sha256="$(sha256sum "$AUTHME_JAR" 2>/dev/null | awk '{print $1}' || true)"
    if [[ "$current_sha256" != "$(sha256sum "$AUTHME_JAR.tmp" | awk '{print $1}')" ]]; then
        mv -f "$AUTHME_JAR.tmp" "$AUTHME_JAR"
        FRESH_INSTALL=true
    else
        rm -f "$AUTHME_JAR.tmp"
    fi

    # AuthMe 6 define sus valores predeterminados en codigo. Solo escribimos los overrides
    # necesarios y los secretos; el plugin completa las propiedades restantes al cargar.
    printf '{}\n' >"$AUTHME_CONFIG.tmp"
    mv -f "$AUTHME_CONFIG.tmp" "$AUTHME_CONFIG"
    python3 "$PROJECT_DIR/scripts/configure-authme.py" "$AUTHME_CONFIG"
}

verify_auth_database() {
    local result

    echo "Verificando la conexion SSL de AuthMe con Supabase..."
    result="$(
        PGPASSWORD="$AUTH_DB_PASSWORD" \
        PGCONNECT_TIMEOUT=15 \
        PGSSLMODE=require \
        psql \
            --host="$AUTH_DB_HOST" \
            --port="${AUTH_DB_PORT:-5432}" \
            --username="$AUTH_DB_USER" \
            --dbname="${AUTH_DB_NAME:-postgres}" \
            --no-password \
            --tuples-only \
            --no-align \
            --command="select case when current_schema() is not null and has_schema_privilege(current_user, current_schema(), 'CREATE') then 'READY' else 'NO_CREATE' end"
    )"
    [[ "$result" == "READY" ]] || {
        echo "Supabase respondio, pero el rol no puede crear la tabla de AuthMe en su esquema activo."
        exit 1
    }
    echo "Conexion con Supabase exitosa."
}

send_command() {
    if [[ "$CONSOLE_FD_OPEN" == true ]] && [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        printf '%s\n' "$1" >&3
    fi
}

sync_live_world() {
    echo "Pausando guardado para crear un respaldo consistente en Oracle..."
    send_command "save-off"
    send_command "save-all flush"
    sleep 10

    local result=0
    sync_files || result=$?
    send_command "save-on"
    return "$result"
}

run_playit() {
    local attempt=1

    while kill -0 "$SERVER_PID" 2>/dev/null; do
        echo "Iniciando agente de playit (intento $attempt)..."
        if docker run --rm --network host --name minecraft-playit \
            -e SECRET_KEY="$PLAYIT_SECRET" \
            ghcr.io/playit-cloud/playit-agent:1.0; then
            echo "El agente de playit termino normalmente."
        else
            echo "El agente de playit fallo; reintentando con otro relay en 10 segundos."
        fi

        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 10
        attempt=$((attempt + 1))
    done
}

configure_ops() {
    [[ -n "${OPS:-}" ]] || return 0

    for _ in $(seq 1 300); do
        kill -0 "$SERVER_PID" 2>/dev/null || return 0
        if grep -Fq "Done (" logs/latest.log 2>/dev/null; then
            local raw_name name
            local operator_names=()
            IFS=',' read -r -a operator_names <<<"$OPS"

            for raw_name in "${operator_names[@]}"; do
                name="${raw_name//[[:space:]]/}"
                if [[ "$name" =~ ^\.?[A-Za-z0-9_]{1,16}$ ]]; then
                    echo "Concediendo operador a $name..."
                    send_command "op $name"
                else
                    echo "Nombre de operador invalido ignorado: $raw_name"
                fi
            done
            return 0
        fi
        sleep 2
    done

    echo "Minecraft no termino de arrancar a tiempo para configurar OPS."
}

configure_geyser() {
    local geyser_config="plugins/Geyser-Spigot/config.yml"

    for _ in $(seq 1 150); do
        kill -0 "$SERVER_PID" 2>/dev/null || return 1
        if [[ -f "$geyser_config" ]]; then
            if ! grep -Eq '^[[:space:]]*auth-type:[[:space:]]*floodgate([[:space:]]|$)' "$geyser_config"; then
                echo "Configurando Geyser para autenticar Bedrock mediante Floodgate..."
                grep -Eq '^[[:space:]]*auth-type:' "$geyser_config" || {
                    echo "No se encontro auth-type en la configuracion de Geyser."
                    return 1
                }
                sed -i -E 's/^([[:space:]]*auth-type:)[[:space:]]*.*/\1 floodgate/' "$geyser_config"
                send_command "geyser reload"
            fi
            return 0
        fi
        sleep 2
    done

    echo "Geyser no genero su archivo de configuracion a tiempo."
    return 1
}

cleanup() {
    local original_status=$?
    trap - EXIT INT TERM
    set +e

    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Deteniendo Minecraft de forma segura..."
        send_command "save-all flush"
        sleep 10
        send_command "stop"

        for _ in $(seq 1 120); do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 1
        done

        if kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "Minecraft no respondio a stop; enviando SIGTERM."
            kill -TERM "$SERVER_PID"
        fi
        wait "$SERVER_PID"
    fi

    if [[ "$STATE_LOADED" == true ]]; then
        echo "Sincronizando estado final con Oracle Cloud..."
        if ! sync_files && ((original_status == 0)); then
            original_status=1
        fi
    fi

    if docker inspect minecraft-playit >/dev/null 2>&1; then
        docker stop --time 10 minecraft-playit >/dev/null
    fi
    if [[ -n "$PLAYIT_PID" ]]; then
        wait "$PLAYIT_PID"
    fi

    if [[ "$CONSOLE_FD_OPEN" == true ]]; then
        exec 3>&-
    fi

    exit "$original_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$RUNTIME_MINUTES" =~ ^[0-9]+$ ]] || {
    echo "RUNTIME_MINUTES debe ser numerico"
    exit 1
}
((RUNTIME_MINUTES >= 1 && RUNTIME_MINUTES <= 335)) || {
    echo "RUNTIME_MINUTES debe estar entre 1 y 335"
    exit 1
}
[[ -n "${PLAYIT_SECRET:-}" ]] || {
    echo "Falta el secreto PLAYIT_SECRET"
    exit 1
}
for required_var in AUTH_DB_HOST AUTH_DB_USER AUTH_DB_PASSWORD; do
    [[ -n "${!required_var:-}" ]] || {
        echo "Falta el secreto $required_var para AuthMe/Supabase."
        exit 1
    }
done
if [[ -n "${RUN_DEADLINE_EPOCH:-}" ]] && [[ ! "$RUN_DEADLINE_EPOCH" =~ ^[0-9]+$ ]]; then
    echo "RUN_DEADLINE_EPOCH debe ser un timestamp numerico."
    exit 1
fi

mkdir -p "$LOCAL_DIR"

echo "Verificando conexion con Oracle Cloud y el bucket..."
if ! rclone lsf "$REMOTE_PATH/" --max-depth 1 >/dev/null 2>&1; then
    echo "ERROR CRITICO: No se pudo conectar a Oracle Cloud o el bucket '$REMOTE_PATH' no existe/no es accesible."
    echo "Ejecutando prueba detallada para mostrar el error:"
    rclone lsf "$REMOTE_PATH/" --max-depth 1
    exit 1
fi
echo "Conexion con Oracle Cloud exitosa."

echo "Restaurando servidor desde Oracle Cloud..."
rclone sync "$REMOTE_PATH/" "$LOCAL_DIR/" --fast-list
STATE_LOADED=true
cd "$LOCAL_DIR"

FRESH_INSTALL=false
download_paper
download_crossplay_plugins
download_and_configure_authme
verify_auth_database

if ! grep -Eiq '^eula=true$' eula.txt 2>/dev/null; then
    echo "Aceptando el EULA..."
    echo "eula=true" > eula.txt
    FRESH_INSTALL=true
fi

# Java no-premium entra en modo offline y AuthMe protege cada nombre con contrasena.
set_server_property "online-mode" "false"
set_server_property "enforce-secure-profile" "false"
# El mundo antiguo de RLCraft se conserva, pero Paper crea un mundo limpio compatible.
set_server_property "level-name" "paper-world"

# Si fue una instalación o configuración inicial limpia, sube los archivos al bucket de inmediato
if [[ "$FRESH_INSTALL" == true ]]; then
    echo "Instalación limpia detectada. Subiendo archivos iniciales al bucket de Oracle Cloud..."
    sync_files
fi

if [[ -z "${JAVA_OPTS:-}" ]]; then
    JAVA_OPTS="-Xms2G -Xmx12G -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+ParallelRefProcEnabled"
fi
read -r -a java_options <<<"$JAVA_OPTS"

mkfifo server.stdin
exec 3<>server.stdin
CONSOLE_FD_OPEN=true

java "${java_options[@]}" -jar "$PAPER_JAR" --nogui <server.stdin &
SERVER_PID=$!

echo "Servidor iniciado por $RUNTIME_MINUTES minutos."
end_time=$(($(date +%s) + RUNTIME_MINUTES * 60))
if [[ -n "${RUN_DEADLINE_EPOCH:-}" ]] && ((RUN_DEADLINE_EPOCH < end_time)); then
    end_time="$RUN_DEADLINE_EPOCH"
    echo "El cierre se adelantara para reservar tiempo al guardado final de GitHub Actions."
fi

run_playit &
PLAYIT_PID=$!
echo "Supervisor de playit iniciado en segundo plano."
configure_geyser
configure_ops

while kill -0 "$SERVER_PID" 2>/dev/null; do
    remaining=$((end_time - $(date +%s)))
    ((remaining > 0)) || break

    if ((remaining > BACKUP_INTERVAL)); then
        sleep "$BACKUP_INTERVAL"
        kill -0 "$SERVER_PID" 2>/dev/null && sync_live_world
    else
        sleep "$remaining"
    fi
done

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    wait "$SERVER_PID" || true
    echo "Minecraft termino antes del tiempo configurado."
    exit 1
fi

#!/usr/bin/env bash
set -Eeuo pipefail

readonly REMOTE_DIR=/mnt/azure/minecraft
readonly LOCAL_DIR="$RUNNER_TEMP/minecraft"
readonly BACKUP_INTERVAL=900
readonly FORGE_VERSION=1.12.2-14.23.5.2860
readonly FORGE_INSTALLER="forge-$FORGE_VERSION-installer.jar"
readonly FORGE_INSTALLER_SHA1=5e8a91f71ef3d1f77de3f8d3261aedcc2f551c9d

SERVER_PID=""
PLAYIT_PID=""
CONSOLE_FD_OPEN=false
STATE_LOADED=false

sync_files() {
	rsync -rt --delete --modify-window=1 \
		--no-perms --no-owner --no-group \
		--exclude server.stdin \
		"$LOCAL_DIR/" "$REMOTE_DIR/"
}

send_command() {
	if [[ "$CONSOLE_FD_OPEN" == true ]] && [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
		printf '%s\n' "$1" >&3
	fi
}

sync_live_world() {
	echo "Pausando guardado para crear un respaldo consistente..."
	send_command "save-off"
	send_command "save-all flush"
	sleep 10

	local result=0
	sync_files || result=$?
	send_command "save-on"
	return "$result"
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
		echo "Sincronizando estado final con Azure Files..."
		if ! sync_files && ((original_status == 0)); then
			original_status=1
		fi
	fi

	if docker inspect rlcraft-playit >/dev/null 2>&1; then
		docker stop --time 10 rlcraft-playit >/dev/null
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
[[ -d "$REMOTE_DIR" ]] || {
	echo "Falta la carpeta $REMOTE_DIR en Azure Files"
	exit 1
}

mkdir -p "$LOCAL_DIR"
echo "Restaurando servidor desde Azure Files..."
rsync -rt --delete --modify-window=1 --no-perms --no-owner --no-group "$REMOTE_DIR/" "$LOCAL_DIR/"
STATE_LOADED=true
cd "$LOCAL_DIR"

if [[ -z "${SERVER_JAR:-}" ]] && [[ ! -f "forge-$FORGE_VERSION.jar" ]]; then
	echo "Forge no esta instalado; preparando $FORGE_VERSION..."
	curl --fail --location --retry 3 \
		--output "$FORGE_INSTALLER" \
		"https://maven.minecraftforge.net/net/minecraftforge/forge/$FORGE_VERSION/$FORGE_INSTALLER"
	echo "$FORGE_INSTALLER_SHA1  $FORGE_INSTALLER" | sha1sum --check
	java -jar "$FORGE_INSTALLER" --installServer
	rm -f "$FORGE_INSTALLER" "$FORGE_INSTALLER.log"

	[[ -f "forge-$FORGE_VERSION.jar" ]] || {
		echo "El instalador no genero forge-$FORGE_VERSION.jar"
		exit 1
	}
fi

if [[ -z "${SERVER_JAR:-}" ]]; then
	SERVER_JAR="forge-$FORGE_VERSION.jar"
fi

[[ -f "$SERVER_JAR" ]] || {
	echo "No existe $SERVER_JAR"
	exit 1
}
grep -Eiq '^eula=true$' eula.txt 2>/dev/null || {
	echo "Falta eula.txt con eula=true en el servidor almacenado en Azure."
	exit 1
}

if [[ -z "${JAVA_OPTS:-}" ]]; then
	JAVA_OPTS="-Xms2G -Xmx5G -XX:+UseG1GC -XX:MaxGCPauseMillis=100"
fi
read -r -a java_options <<<"$JAVA_OPTS"

mkfifo server.stdin
exec 3<>server.stdin
CONSOLE_FD_OPEN=true

docker run --rm --network host --name rlcraft-playit \
	-e SECRET_KEY="$PLAYIT_SECRET" \
	ghcr.io/playit-cloud/playit-agent:1.0 &
PLAYIT_PID=$!

playit_connected=false
for _ in $(seq 1 30); do
	if [[ "$(docker inspect --format '{{.State.Running}}' rlcraft-playit 2>/dev/null || true)" != true ]]; then
		wait "$PLAYIT_PID" || true
		echo "El agente de playit termino antes de conectarse. Revisa PLAYIT_SECRET."
		exit 1
	fi

	if docker logs rlcraft-playit 2>&1 | grep -Fq "playit connected; tunnels loaded"; then
		playit_connected=true
		break
	fi
	sleep 2
done

if [[ "$playit_connected" != true ]]; then
	echo "El agente de playit no alcanzo ningun relay despues de 60 segundos."
	exit 1
fi
echo "Agente de playit conectado y tuneles cargados."

java "${java_options[@]}" -jar "$SERVER_JAR" nogui <server.stdin &
SERVER_PID=$!

echo "RLCraft iniciado por $RUNTIME_MINUTES minutos."
end_time=$(($(date +%s) + RUNTIME_MINUTES * 60))

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

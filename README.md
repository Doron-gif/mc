# RLCraft temporal con GitHub Actions

Servidor experimental de RLCraft 1.12.2 ejecutado en dos turnos diarios. El horario configurado es:

- 00:00 de Peru: primer turno.
- 06:00 de Peru: segundo turno.
- Cada turno permite hasta 335 minutos para dejar margen antes del limite de seis horas del runner.
- GitHub puede retrasar los jobs programados, por lo que no se garantiza disponibilidad continua hasta las 12:00.

El servidor se ejecuta en el disco local del runner. Cada 15 minutos se pausa el guardado, se ejecuta `save-all flush`, se sincroniza con Azure Files y se reactiva el guardado. Al finalizar se envia `stop` y se realiza una sincronizacion final.

## Preparar Azure Files

Crea una carpeta llamada `minecraft` en la raiz del File Share. Sube dentro de ella el contenido completo del Server Pack oficial de RLCraft, no el modpack de cliente.

La estructura minima esperada es:

```text
minecraft/
  eula.txt
  server.properties
  mods/
  config/
  scripts/
```

`eula.txt` debe contener `eula=true`. Para permitir clientes sin autenticacion oficial, `server.properties` debe contener `online-mode=false`.

Es normal que este Server Pack no incluya los JAR. En el primer arranque, el workflow descarga el instalador oficial, verifica su SHA-1 e instala Forge `14.23.5.2860`. Los archivos `forge-1.12.2-14.23.5.2860.jar`, `minecraft_server.1.12.2.jar` y `libraries/` se guardaran despues en Azure Files.

Conserva esta version de Forge aunque exista una mas reciente, porque es la version utilizada por RLCraft 2.9.3.

## Secretos de GitHub

Configura estos secretos en `Settings > Secrets and variables > Actions`:

| Secreto                 | Contenido                             |
| ----------------------- | ------------------------------------- |
| `AZURE_STORAGE_ACCOUNT` | Nombre de la cuenta de almacenamiento |
| `AZURE_STORAGE_KEY`     | Clave de acceso de la cuenta          |
| `AZURE_SHARE_NAME`      | Nombre del File Share                 |
| `PLAYIT_SECRET`         | Secret key del agente de playit.gg    |

Variables opcionales del repositorio:

| Variable     | Valor sugerido                                                  |
| ------------ | --------------------------------------------------------------- |
| `SERVER_JAR` | Nombre exacto del JAR de Forge si la deteccion automatica falla |
| `JAVA_OPTS`  | `-Xms2G -Xmx5G -XX:+UseG1GC -XX:MaxGCPauseMillis=100`           |

En playit.gg crea un tunel Minecraft Java hacia `127.0.0.1:25565` y usa su secret key como `PLAYIT_SECRET`.

## Primera prueba

1. Sube el Server Pack a Azure Files.
2. Configura los cuatro secretos.
3. Abre `Actions > RLCraft temporal > Run workflow`.
4. Usa entre 10 y 30 minutos para la primera prueba.
5. Revisa que aparezcan el mundo y los logs actualizados en `minecraft/` dentro de Azure Files.

Los horarios automaticos solo funcionan cuando el workflow se encuentra en la rama predeterminada del repositorio.

## Limitaciones

GitHub Actions esta destinado a desarrollo, pruebas y despliegues, no a hosting permanente. GitHub puede cancelar o restringir este uso. Tampoco existe garantia de arranque puntual, continuidad entre turnos ni ejecucion del respaldo si el runner desaparece abruptamente.

# Servidor Paper no-premium con crossplay

Servidor temporal de **Paper 26.2** para Minecraft Java no-premium y Minecraft
Bedrock de Android. El workflow usa Java 25 y actualiza en cada arranque:

- La compilacion estable mas reciente de Paper 26.2.
- Geyser-Spigot, que traduce el protocolo Bedrock al de Java.
- Floodgate-Spigot, que identifica jugadores Bedrock.
- AuthMe 6.0.0 para `/register` y `/login`.

Geyser soporta actualmente Bedrock 26.0 a 26.40 y Java 26.2. Se actualiza en
cada arranque porque Bedrock de Android tambien se actualiza automaticamente.

## Como entran los jugadores

```text
Java no-premium -> playit TCP -> Paper :25565 -> AuthMe -> Supabase Postgres
Android         -> playit UDP -> Geyser :19132 -> Floodgate -> AuthMe
```

El servidor usa `online-mode=false`. Todo jugador nuevo, incluido Bedrock, se
registra una sola vez:

```text
/register contraseña contraseña
```

En las siguientes conexiones usa:

```text
/login contraseña
```

Se exige una contraseña de al menos 10 caracteres. Debe ser exclusiva para
este servidor y no reutilizarse en correo, Microsoft, Discord ni otros sitios.

## Como se guardan las contraseñas

AuthMe no guarda el texto original. Genera un salt aleatorio y un hash
**Argon2id**; Supabase almacena el hash y los parametros necesarios para volver
a calcularlo. Al iniciar sesion, AuthMe calcula el hash de lo escrito y compara
el resultado. Un hash no se puede descifrar como si fuera texto cifrado, aunque
una contraseña debil todavia puede adivinarse por fuerza bruta.

Hay dos conexiones diferentes:

- Paper a Supabase usa PostgreSQL con SSL.
- Java no-premium a Paper no tiene el cifrado normal de `online-mode`.

Por esa segunda limitacion, incluso usando Argon2id se debe utilizar una
contraseña exclusiva para el servidor. El hash protege la base de datos; no
convierte el protocolo offline de Minecraft en una conexion cifrada de extremo
a extremo.

## Configurar Supabase

Usa un proyecto Supabase activo. No se necesita Supabase Auth, REST ni una tabla
publica: AuthMe se conecta directamente a PostgreSQL.

Para evitar entregar a Minecraft el usuario administrador, ejecuta una vez este
SQL en el SQL Editor. Sustituye la contraseña por una aleatoria, por ejemplo una
generada con `openssl rand -hex 32`:

```sql
do $$
begin
  if not exists (
    select 1 from pg_roles where rolname = 'minecraft_authme'
  ) then
    create role minecraft_authme;
  end if;
end
$$;

alter role minecraft_authme
  login
  password 'REEMPLAZA_CON_UNA_CLAVE_ALEATORIA';

grant connect on database postgres to minecraft_authme;

create schema if not exists minecraft_auth;
revoke all on schema minecraft_auth from public;
grant usage, create on schema minecraft_auth to minecraft_authme;
revoke create on schema public from minecraft_authme;

alter role minecraft_authme in database postgres
  set search_path = minecraft_auth, pg_catalog;
```

El esquema queda administrado por el usuario del SQL Editor y el rol de AuthMe
solamente recibe `USAGE` y `CREATE` dentro de `minecraft_auth`. Las tablas que
cree AuthMe quedan bajo su propio control sin darle acceso de administrador.
Como el esquema no esta expuesto por la Data API, los hashes no quedan
consultables con las claves `anon` o `authenticated`.

En `Connect > Session pooler` copia los datos de conexion. GitHub Actions usa
IPv4 y AuthMe mantiene conexiones JDBC, por lo que debe usarse **Session mode,
puerto 5432**, no Transaction mode 6543.

Configura estos GitHub Secrets:

| Secreto | Contenido |
| --- | --- |
| `RCLONE_CONF` | Configuracion de rclone con el remoto `oracle-mc` |
| `PLAYIT_SECRET` | Secret key del agente de playit.gg |
| `AUTH_DB_HOST` | Host del Session pooler, por ejemplo `aws-0-...pooler.supabase.com` |
| `AUTH_DB_USER` | `minecraft_authme.REF_DEL_PROYECTO` |
| `AUTH_DB_PASSWORD` | La contraseña aleatoria del rol |

Variables opcionales:

| Variable | Valor predeterminado |
| --- | --- |
| `AUTH_DB_PORT` | `5432` |
| `AUTH_DB_NAME` | `postgres` |
| `AUTH_DB_TABLE` | `authme` |
| `PAPER_VERSION` | `26.2` |
| `JAVA_OPTS` | `-Xms2G -Xmx12G -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+ParallelRefProcEnabled` |
| `OPS` | Nombres separados por comas; Bedrock normalmente comienza con `.` |

La contraseña de PostgreSQL solo existe como GitHub Secret y dentro del runner
mientras esta funcionando. `plugins/AuthMe/config.yml` se genera en cada run y
esta excluido de la sincronizacion con Oracle.

## Persistencia al terminar cada run

Los datos se dividen asi:

- Los registros y hashes de AuthMe se escriben inmediatamente en Supabase.
- El mundo, inventarios, plugins y configuraciones no secretas se guardan en
  `oracle-mc:minecraft-bucket`.
- Cada 15 minutos se ejecuta `save-off`, `save-all flush`, rclone y `save-on`.
- Como maximo a los 335 minutos desde que comienza el job se envia
  `save-all flush` y `stop`, se espera a que Paper y AuthMe cierren, y despues
  se realiza una sincronizacion final.

El workflow tiene 355 minutos de limite. El plazo de cierre se calcula en el
primer paso del job, por lo que descargas y restauraciones tambien consumen los
335 minutos y siempre quedan aproximadamente 20 minutos para cerrar y copiar.
Si el runner desaparece sin permitir el cierre, los usuarios de AuthMe siguen
seguros en Supabase y el mundo puede perder como maximo los cambios posteriores
a la ultima copia periodica.

El mundo viejo de RLCraft no es compatible con Paper. Se conserva sin cargar y
Paper crea un mundo nuevo llamado `paper-world`.

## Tuneles de playit.gg

Crea dos tuneles con la misma secret key del agente:

1. Minecraft Java, TCP, destino `127.0.0.1:25565`.
2. Minecraft Bedrock, UDP, destino `127.0.0.1:19132`.

Java usa la direccion del primer tunel. Android agrega un servidor externo con
la direccion y puerto del segundo.

## Primera prueba

1. Haz una copia del bucket anterior de RLCraft.
2. Configura Supabase, los GitHub Secrets y los dos tuneles.
3. Ejecuta `Actions > Minecraft Paper Crossplay > Run workflow` durante 10 a 30
   minutos.
4. Comprueba que carguen Paper, Geyser, Floodgate y AuthMe.
5. Registra una cuenta Java no-premium y una cuenta Android.
6. Deten el run y confirma que el mismo usuario puede volver a usar `/login` en
   el siguiente run.

GitHub Actions esta orientado a automatizacion y pruebas, no garantiza hosting
continuo ni arranques puntuales. El workflow conserva los horarios existentes.

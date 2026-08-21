# vectores_iris

Demo mínima de **búsqueda vectorial nativa + RAG** sobre InterSystems IRIS.

El flujo completo es: un texto se convierte en embedding con la API de OpenAI, se guarda en una columna `VECTOR(DOUBLE, 1536)` de IRIS, y una consulta SQL recupera el documento más parecido a una pregunta (`VECTOR_DOT_PRODUCT`) y se lo pasa a GPT para que responda. Todo desde ObjectScript y SQL, sin librerías externas.

```
pregunta ──► embedding (OpenAI) ──► VECTOR_DOT_PRODUCT ──► documento más cercano ──► GPT ──► respuesta
```

---

## Requisitos

- Docker con una imagen de IRIS 2024.1 o superior (el tipo `VECTOR` no existe antes).
- Una API key de OpenAI **con saldo**. Una key válida sin créditos devuelve `429 credit_balance_exhausted`.
- Opcional: VS Code con las extensiones *InterSystems ObjectScript* y *SQLTools*.

---

## Los archivos, uno por uno

| Archivo | Qué es | Cuándo se usa |
|---|---|---|
| [`Utils.cls`](Utils.cls) | El motor: clase `User.Utils` con toda la lógica. | Se carga y compila una vez. |
| [`SeedData.mac`](SeedData.mac) | Rutina de arranque: prepara el entorno y carga el primer documento. | Se ejecuta para poblar la base. |
| [`Create_table.sql`](Create_table.sql) | El DDL de la tabla, suelto, como referencia. | Solo si querés crear la tabla a mano. |
| [`Slect table vectors.sql`](Slect%20table%20vectors.sql) | La consulta RAG de ejemplo. | Es la demo final. |
| [`docker-compose.yml`](docker-compose.yml) | Levanta el IRIS de la demo. | Paso 1 de la instalación. |
| [`.vscode/settings.json`](.vscode/settings.json) | Conexión al IRIS de Docker. | Lo lee VS Code. |
| [`LICENSE`](LICENSE) | Licencia MIT. | — |

### `Utils.cls` — la clase `User.Utils`

Los métodos que hacen el trabajo, dos de ellos publicados como funciones SQL (`SqlProc`), que es lo que permite llamarlos desde dentro de un `SELECT`:

- **`Setup()`** — idempotente. Crea la configuración SSL `DefaultSSL` en `%SYS` (sin ella IRIS no puede hablar HTTPS con OpenAI) y crea la tabla `VECTORESPKG.Documentos`. Si ya existen, lo dice y sigue.
- **`ObtenerEmbedding(texto)`** — `POST /v1/embeddings` con `text-embedding-3-small`. Devuelve el vector como string JSON `[0.1, -0.3, ...]`, que es lo que `TO_VECTOR()` sabe convertir. Devuelve `"[]"` si falla.
- **`EnviarAGPT(contexto, instruccion)`** — `POST /v1/chat/completions` con `gpt-4o-mini`. Devuelve el texto de la respuesta.
- **`ApiKey()` / `SetApiKey(key)`** — la credencial **no está en el código**: se lee de la global `^Config("OpenAIKey")` y, si está vacía, de la variable de entorno `OPENAI_API_KEY`.

Los dos métodos HTTP aceptan streams además de strings, porque `Contenido` es `VARCHAR(MAX)` y SQL se los pasa como `%Stream.Object`.

### `SeedData.mac` — la rutina `^SeedData`

Script de un solo uso que hace, en orden: entra al namespace `VECTORES`, llama a `Setup()`, genera el embedding de un texto de ejemplo, y lo inserta con `INSERT ... VALUES (?, ?, TO_VECTOR(?, DOUBLE))`. Aborta con un mensaje claro en cada paso que pueda fallar. Para cargar tus propios documentos, cambiá las variables `texto` y `nombre`.

### `Create_table.sql`

```sql
CREATE TABLE VECTORESPKG.Documentos (
    ID INTEGER PRIMARY KEY IDENTITY,
    Nombre VARCHAR(255),
    Contenido VARCHAR(MAX),
    Embedding VECTOR(DOUBLE, 1536)
)
```

El `1536` no es arbitrario: es la dimensión de `text-embedding-3-small`. Si cambiás de modelo de embeddings, tenés que cambiar ese número y recrear la tabla. Este archivo es redundante con `Setup()` —que ejecuta el mismo DDL— y está para poder crear la tabla desde el portal si preferís.

### `Slect table vectors.sql` — la demo

```sql
SELECT TOP 1 ID, Nombre, EnviarAGPT(Contenido, 'Responde sobre:') AS RespuestaGPT
FROM VECTORESPKG.Documentos
ORDER BY VECTOR_DOT_PRODUCT(
    Embedding,
    TO_VECTOR(ObtenerEmbedding('¿Qué dice sobre IRIS?'), double)
) DESC
```

Se lee de abajo hacia arriba y ahí se ve el RAG entero: el `ORDER BY` convierte la pregunta en vector y ordena por similitud, el `TOP 1` se queda con el documento más cercano, y el `SELECT` le manda ese contenido a GPT. Tarda ~3,5 s porque hace dos llamadas a OpenAI por ejecución.

---

## Instalación

### 1. Levantar IRIS

```bash
docker compose up -d
```

Verificá que responde y que la clave es la correcta:

```bash
curl -u SuperUser:SYS -o /dev/null -w "%{http_code}\n" http://localhost:52773/api/atelier/
# 200 = ok · 401 = clave incorrecta
```

### 2. Crear el namespace `VECTORES`

Ninguna imagen lo trae de fábrica. Desde el **Portal de Administración** → *System Administration > Configuration > System Configuration > Namespaces > Create New Namespace* (creando también una base de datos nueva para él), o por terminal:

```bash
docker exec -i iris-vectores iris session IRIS -U "%SYS"
```

```objectscript
set dbDir="/usr/irissys/mgr/VECTORES/"
do ##class(%File).CreateDirectoryChain(dbDir)
do ##class(SYS.Database).CreateDatabase(dbDir)
set p("Directory")=dbDir  do ##class(Config.Databases).Create("VECTORES",.p)
set n("Globals")="VECTORES",n("Routines")="VECTORES"  do ##class(Config.Namespaces).Create("VECTORES",.n)
```

> Si tu imagen usa almacenamiento durable (`/durable/irissys/mgr/`), creá la base ahí para que sobreviva a recrear el contenedor.

### 3. Cargar el código

Con VS Code: abrí la carpeta, conectá al servidor y *Import and Compile* sobre `Utils.cls` y `SeedData.mac`.

Por línea de comandos:

```bash
docker exec iris-vectores mkdir -p /tmp/src
docker cp Utils.cls    iris-vectores:/tmp/src/Utils.cls
docker cp SeedData.mac iris-vectores:/tmp/src/SeedData.mac
docker exec -i iris-vectores iris session IRIS -U "VECTORES"
```

```objectscript
do $SYSTEM.OBJ.Load("/tmp/src/Utils.cls","ck")
do $SYSTEM.OBJ.Load("/tmp/src/SeedData.mac","ck")
```

> **Git Bash / MINGW en Windows:** antepone la raíz de Windows a las rutas `/tmp/...` y `docker cp` falla con *"Could not find the file"*. Se corrige con `export MSYS_NO_PATHCONV=1` antes de los comandos.

### 4. Configurar la API key

La key **no se escribe en el código**. Una sola vez, dentro del namespace `VECTORES`:

```objectscript
do ##class(User.Utils).SetApiKey("sk-proj-...")
```

Queda en la global `^Config("OpenAIKey")` de ese namespace. La alternativa es exportar `OPENAI_API_KEY` en el entorno antes de levantar el contenedor: `docker-compose.yml` ya la pasa.

### 5. Poblar y probar

```objectscript
do ^SeedData
```

```
Configurando entorno...
Creando configuración SSL 'DefaultSSL'...
Tabla VECTORESPKG.Documentos creada exitosamente.
Generando embedding...
Embedding generado correctamente.
¡Éxito! Ya tienes un vector real en la tabla.
```

Ahora pegá el contenido de [`Slect table vectors.sql`](Slect%20table%20vectors.sql) en el Portal (*System Explorer > SQL*, namespace `VECTORES`) y ejecutá. Deberías obtener una fila con la respuesta de GPT basada en el documento recuperado.

---

## Uso diario

**Agregar un documento** — editá `texto` y `nombre` en `SeedData.mac` y volvé a ejecutar `do ^SeedData`, o hacelo directo por SQL:

```sql
INSERT INTO VECTORESPKG.Documentos (Nombre, Contenido, Embedding)
VALUES ('Mi doc', 'El texto...', TO_VECTOR(ObtenerEmbedding('El texto...'), DOUBLE))
```

**Preguntar otra cosa** — cambiá el texto dentro de `ObtenerEmbedding(...)` en el `ORDER BY`.

**Ver la similitud sin gastar en GPT** — útil para depurar el ranking:

```sql
SELECT TOP 5 ID, Nombre,
       VECTOR_DOT_PRODUCT(Embedding, TO_VECTOR(ObtenerEmbedding('tu pregunta'), double)) AS Sim
FROM VECTORESPKG.Documentos ORDER BY 3 DESC
```

Con vectores normalizados —como los de OpenAI— `VECTOR_DOT_PRODUCT` equivale al coseno; IRIS también ofrece `VECTOR_COSINE()` si preferís ser explícito.

---

## Seguridad

- La API key vive en la global `^Config("OpenAIKey")` o en `OPENAI_API_KEY`, nunca en el repositorio. Si alguna vez la escribís en el código y hacés commit, **revocala** en el panel de OpenAI: rotarla no borra el historial de Git.
- `.vscode/settings.json` trae `SuperUser`/`SYS`, que son las credenciales por defecto de una instancia de desarrollo. Cambialas antes de exponer la instancia a una red.

---

## Problemas frecuentes

| Síntoma | Causa |
|---|---|
| `Error API Code: 429` / `credit_balance_exhausted` | La cuenta de OpenAI no tiene créditos. El saldo es **por organización**: generar una key nueva no lo resuelve. |
| `Error API Code: 401` | Key inválida o revocada. |
| `no hay API key configurada` | Falta el paso 4 (`SetApiKey`) en ese namespace. |
| `ERROR #5012: File does not exist` al cargar | Las rutas se manglaron en Git Bash → `export MSYS_NO_PATHCONV=1`. |
| `<NAMESPACE>` o falla el `ZNspace` | Falta crear el namespace `VECTORES` (paso 2). |
| Error de SSL al llamar a OpenAI | Falta `DefaultSSL`. La crea `Setup()`; verificalo en *System Administration > Security > SSL/TLS Configurations*. |
| Acentos rotos en la terminal de `iris session` | Es la consola del contenedor (cp437), no el dato. Desde el Portal o VS Code se ve bien. |

---

## Licencia

MIT — ver [LICENSE](LICENSE). Copyright (c) 2026 Bismar Vargas Arias.

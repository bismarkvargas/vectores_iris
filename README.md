# vectores_iris

Demo mínima de **búsqueda vectorial nativa + RAG** sobre InterSystems IRIS.

El flujo completo es: un texto se convierte en embedding con la API de OpenAI, se guarda en una columna `VECTOR(DOUBLE, 1536)` de IRIS, y una consulta SQL recupera el documento más parecido a una pregunta (`VECTOR_DOT_PRODUCT`) y se lo pasa a GPT para que responda. Todo desde ObjectScript y SQL, sin librerías externas.

```
pregunta ──► embedding (OpenAI) ──► VECTOR_DOT_PRODUCT ──► documento más cercano ──► GPT ──► respuesta
```

---

## Requisitos

- IRIS 2024.1 o superior (el tipo `VECTOR` no existe antes). El `docker-compose.yml` incluido levanta uno.
- Una API key de OpenAI **con saldo**. Una key válida sin créditos devuelve `429 credit_balance_exhausted`.
- Opcional: VS Code con las extensiones *InterSystems ObjectScript* y *SQLTools*.

---

## Los archivos, uno por uno

| Archivo | Qué es | Cuándo se usa |
|---|---|---|
| [`src/User/Utils.cls`](src/User/Utils.cls) | El motor: clase `User.Utils` con toda la lógica. | Se carga y compila una vez. |
| [`src/SeedData.mac`](src/SeedData.mac) | Rutina de arranque: prepara el entorno y carga el primer documento. | Se ejecuta para poblar la base. |
| [`Create_table.sql`](Create_table.sql) | El DDL de la tabla, suelto, como referencia. | Solo si querés crear la tabla a mano. |
| [`Slect table vectors.sql`](Slect%20table%20vectors.sql) | La consulta RAG de ejemplo. | Es la demo final. |
| [`module.xml`](module.xml) | Manifiesto de IPM/ZPM para instalar como paquete. | `zpm "load ."` |
| [`docker-compose.yml`](docker-compose.yml) | Levanta el IRIS de la demo. | Paso 1 de la instalación. |
| [`.vscode/settings.json`](.vscode/settings.json) | Conexión al IRIS de Docker. | Lo lee VS Code. |
| [`LICENSE`](LICENSE) | Licencia MIT. | — |

### `src/User/Utils.cls` — la clase `User.Utils`

Los métodos que hacen el trabajo, dos de ellos publicados como funciones SQL (`SqlProc`), que es lo que permite llamarlos desde dentro de un `SELECT`:

- **`Setup()`** — idempotente. Crea la configuración SSL `DefaultSSL` en `%SYS` (sin ella IRIS no puede hablar HTTPS con OpenAI) y crea la tabla `VECTORESPKG.Documentos` **en el namespace actual**. Si ya existen, lo dice y sigue.
- **`ObtenerEmbedding(texto)`** — `POST /v1/embeddings` con `text-embedding-3-small`. Devuelve el vector como string JSON `[0.1, -0.3, ...]`, que es lo que `TO_VECTOR()` sabe convertir. Devuelve `"[]"` si falla.
- **`EnviarAGPT(contexto, instruccion)`** — `POST /v1/chat/completions` con `gpt-4o-mini`. Devuelve el texto de la respuesta.
- **`ApiKey()` / `SetApiKey(key)`** — la credencial **no está en el código**: se lee de la global `^Config("OpenAIKey")` y, si está vacía, de la variable de entorno `OPENAI_API_KEY`.

Los dos métodos HTTP aceptan streams además de strings, porque `Contenido` es `VARCHAR(MAX)` y SQL se los pasa como `%Stream.Object`.

### `src/SeedData.mac` — la rutina `^SeedData`

Script de un solo uso que hace, en orden: llama a `Setup()`, genera el embedding de un texto de ejemplo, y lo inserta con `INSERT ... VALUES (?, ?, TO_VECTOR(?, DOUBLE))`. Aborta con un mensaje claro en cada paso que pueda fallar. Trabaja sobre el namespace en el que la ejecutés. Para cargar tus propios documentos, cambiá las variables `texto` y `nombre`.

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

### 2. Cargar el código

**Opción A — con IPM/ZPM** (recomendada). Desde una terminal de IRIS, en el namespace donde quieras la demo:

```objectscript
zpm "load /ruta/al/repo"
```

Instala la clase y la rutina en ese namespace. Si el repo está montado en el contenedor —el `docker-compose.yml` lo monta en `/home/irisowner/src`— alcanza con `zpm "load /home/irisowner/src"`.

**Opción B — a mano**, útil si no tenés IPM:

```bash
docker exec iris-vectores mkdir -p /tmp/src
docker cp src/User/Utils.cls iris-vectores:/tmp/src/Utils.cls
docker cp src/SeedData.mac   iris-vectores:/tmp/src/SeedData.mac
docker exec -i iris-vectores iris session IRIS
```

```objectscript
do $SYSTEM.OBJ.Load("/tmp/src/Utils.cls","ck")
do $SYSTEM.OBJ.Load("/tmp/src/SeedData.mac","ck")
```

Con VS Code: abrí la carpeta, conectá al servidor y *Import and Compile*.

> **Git Bash / MINGW en Windows:** antepone la raíz de Windows a las rutas `/tmp/...` y `docker cp` falla con *"Could not find the file"*. Se corrige con `export MSYS_NO_PATHCONV=1` antes de los comandos.

### 3. Configurar la API key

La key **no se escribe en el código**. Una sola vez, en el namespace donde instalaste:

```objectscript
do ##class(User.Utils).SetApiKey("sk-proj-...")
```

Queda en la global `^Config("OpenAIKey")` de ese namespace. La alternativa es exportar `OPENAI_API_KEY` en el entorno antes de levantar el contenedor: `docker-compose.yml` ya la pasa.

### 4. Poblar y probar

```objectscript
do ^SeedData
```

```
Namespace: VECTORES
Configurando entorno...
Creando configuración SSL 'DefaultSSL'...
Tabla VECTORESPKG.Documentos creada exitosamente.
Generando embedding...
Embedding generado correctamente.
¡Éxito! Ya tienes un vector real en la tabla.
```

Ahora pegá el contenido de [`Slect table vectors.sql`](Slect%20table%20vectors.sql) en el Portal (*System Explorer > SQL*) y ejecutá. Deberías obtener una fila con la respuesta de GPT basada en el documento recuperado.

> ¿Querés un namespace dedicado `VECTORES` como el de la demo original? Crealo desde el Portal (*System Administration > Configuration > System Configuration > Namespaces*) antes del paso 2 e instalá ahí. El código funciona en cualquier namespace.

---

## Uso diario

**Agregar un documento** — editá `texto` y `nombre` en `src/SeedData.mac` y volvé a ejecutar `do ^SeedData`, o hacelo directo por SQL:

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
| `no hay API key configurada` | Falta el paso 3 (`SetApiKey`) en ese namespace. |
| `ERROR #5012: File does not exist` al cargar | Las rutas se manglaron en Git Bash → `export MSYS_NO_PATHCONV=1`. |
| Error de SSL al llamar a OpenAI | Falta `DefaultSSL`. La crea `Setup()`; verificalo en *System Administration > Security > SSL/TLS Configurations*. |
| Acentos rotos en la terminal de `iris session` | Es la consola del contenedor (cp437), no el dato. Desde el Portal o VS Code se ve bien. |

---

## Licencia

MIT — ver [LICENSE](LICENSE). Copyright (c) 2026 Bismar Vargas Arias.

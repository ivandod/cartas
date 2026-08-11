# Cartas v1.9.0-rc7

Addon para World of Warcraft Retail / Midnight que conserva la correspondencia
enviada y recibida y la presenta como conversaciones.

## Seguridad del historial

- Las cartas enviadas ya no se limitan a 500 registros.
- No se elimina ninguna carta mediante deduplicación heurística.
- Eliminar u "Eliminar todo" solo oculta registros; Restaurar los recupera.
- `/cartas limpiar` abre una confirmación y tampoco destruye datos.
- El almacén permanente de recibidos nunca se reconstruye desde el buzón actual.
- Auction House, Customer Support y demás correo de sistema permanecen en el
  buzón/archivo, pero nunca se muestran como conversaciones.

El cuerpo de una carta recibida solo puede guardarse después de que Blizzard lo
haya cargado. Cartas conserva siempre la cabecera, pero una carta que caduque sin
haberse abierto puede quedarse sin cuerpo porque la API de WoW no lo entrega.

Cartas nunca solicita en segundo plano el cuerpo de una carta que Blizzard
marque como no leída. Abrir o actualizar la ventana conserva el estado NUEVA;
solo Leer/Ver o abrirla desde el buzón de Blizzard solicita el cuerpo.

## Búsqueda

La búsqueda no requiere reino. Es parcial, literal e insensible a mayúsculas:
`Arian` encuentra `Arianna` y `Arianna-ReinoPrueba`. Si se escribe
`Arian-Reino`, también se filtra parcialmente por reino.

Los hilos normalizan respuestas con `RE:`, cadenas `RE: RE:` y la variante
irregular `RE RE:`. Una carta sin prefijo y sus respuestas se agrupan cuando el
asunto base y el interlocutor coinciden.

## Límites de escritura

La ventana de escritura replica los límites de WoW 12.0.7: 64 caracteres para
el asunto y 500 para el cuerpo. Ambos campos muestran un contador y dejan de
aceptar texto al alcanzar su máximo. Responder reutiliza un único prefijo `RE:`
para no consumir el asunto con cadenas como `RE: RE: RE:`.

Las respuestas nuevas mantienen el mismo hilo porque la conversación usa el
asunto base y el interlocutor. Dentro del hilo, las cartas se muestran por fecha
y secuencia; la cantidad histórica de prefijos `RE:` no altera el orden.

## Secciones desplegables

El historial agrupa primero por personaje y después por conversación. Los
interlocutores aparecen contraídos inicialmente y muestran cuántas conversaciones,
cartas y mensajes nuevos contienen. Cada conversación también se puede desplegar
por separado y muestra su número de cartas y mensajes nuevos. Al buscar un
personaje, sus resultados se abren automáticamente.

BUZÓN ACTUAL es desplegable y empieza abierto. La ventana carga sus correos en la
primera apertura sin tener que pulsar Buscar.

## Uso

- `/cartas` abre el historial.
- `/correspondencia NOMBRE` muestra la correspondencia con un personaje.
- `/cartas limpiar` oculta todo el historial después de confirmar.
- `/cartas restaurar` recupera todas las cartas ocultas.
- El botón C del buzón abre Cartas.
- Leer/Ver carga y archiva el cuerpo que Blizzard exponga.
- Recoger y Responder actúan sobre el correo real del buzón.

## Pruebas locales

Requiere Lua 5.1. En Windows puede instalarse con:

`winget install --id rjpcomputing.luaforwindows --exact`

Desde la carpeta del addon:

`powershell -ExecutionPolicy Bypass -File .\tests\run.ps1`

Para validar además un SavedVariables real sin escribirlo:

`powershell -ExecutionPolicy Bypass -File .\tests\run.ps1 -SavedVariables "RUTA\Cartas.lua"`

La arquitectura, limitaciones y reglas de persistencia están en
`docs/ARCHITECTURE.md`. El procedimiento de backup y rollback está en
`docs/RECOVERY.md`.

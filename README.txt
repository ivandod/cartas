# Cartas v1.10.1

Addon para World of Warcraft Retail / Midnight que conserva la correspondencia
enviada y recibida y la presenta como conversaciones.

## Seguridad del historial

- Las cartas enviadas ya no se limitan a 500 registros.
- No se elimina ninguna carta mediante deduplicación heurística.
- Eliminar u "Eliminar todo" dentro del historial solo oculta registros;
  Restaurar los recupera.
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

La ventana de escritura replica los límites de WoW 12.1.0: 64 caracteres para
el asunto y 500 para el cuerpo. Ambos campos muestran un contador y dejan de
aceptar texto al alcanzar su máximo. Responder reutiliza un único prefijo `RE:`
para no consumir el asunto con cadenas como `RE: RE: RE:`.

Las respuestas nuevas mantienen el mismo hilo porque la conversación usa el
asunto base y el interlocutor. Dentro del hilo, las cartas se muestran por fecha
y secuencia; la cantidad histórica de prefijos `RE:` no altera el orden.

## Orden cronológico

Las cartas enviadas y recibidas se intercalan por timestamp dentro de cada
conversación. WoW puede informar `daysLeft` por encima de 30 para correo normal;
Cartas usa el horizonte real de 31 días para que una recibida nueva nunca quede
fechada en el futuro.

Al cargar esta versión se corrigen los timestamps futuros creados por versiones
anteriores. La fecha y el timestamp previos se conservan como metadatos de
respaldo; la reparación no elimina ni fusiona cartas.

Las versiones que pasaron del horizonte antiguo de 30 días al actual de 31
pudieron volver a archivar una carta cuando esta cambió de fila en el buzón.
Cartas reconoce únicamente esa firma técnica completa y omite la copia antigua
en la vista. Ambos registros siguen intactos en el archivo. Dos cartas iguales
sin esa prueba se mantienen como cartas independientes.

## Secciones desplegables

El historial agrupa primero por personaje y después por conversación. Los
interlocutores aparecen contraídos inicialmente y muestran cuántas conversaciones,
cartas y mensajes nuevos contienen. Cada conversación también se puede desplegar
por separado y muestra su número de cartas y mensajes nuevos. Al buscar un
personaje, sus resultados se abren automáticamente.

BUZÓN ACTUAL es desplegable y empieza abierto. La ventana carga sus correos en la
primera apertura sin tener que pulsar Buscar.

El botón Borrar elimina el correo real del buzón de Blizzard después de una
confirmación. Antes solicita y archiva su cuerpo. Si detecta objetos, dinero o
un pago contra reembolso, cancela el borrado y pide gestionar primero el
contenido. Los correos que WoW solo permite devolver tampoco se devuelven de
forma automática. La copia histórica de Cartas permanece intacta.

## Apariencia

El botón Apariencia permite alternar entre dos presentaciones sin recargar:

- Clásico: recupera el panel oscuro y compacto del addon.
- Pergamino: usa tinta oscura, papel opaco y texturas incluidas en WoW.

La opacidad de los fondos se ajusta entre 55% y 100%; el texto permanece opaco
para conservar su legibilidad. El buscador usa siempre un fondo opaco acorde al
tema para que el nombre escrito no se mezcle con la textura de la ventana.

En el mismo diálogo se puede ajustar el ancho y el alto de la ventana. El cambio
se previsualiza inmediatamente y se limita al espacio disponible en pantalla.
Al reducir el ancho, los controles superiores se reparten automáticamente en
dos filas para conservar un modo compacto sin solapamientos. El ancho mínimo es
760, frente a los 960 de la iteración anterior.
Pergamino al 100% y un tamaño de 1020 x 720 son los valores predeterminados.
Estas preferencias se guardan en `CartasDB.ui` y no modifican ninguna carta.

La organización manual se ha retirado de esta versión. Si una iteración local
anterior creó `threadOrganization`, sus datos se conservan pero no se leen ni se
presentan en la interfaz.

## Uso

- `/cartas` abre el historial.
- `/correspondencia NOMBRE` muestra la correspondencia con un personaje.
- `/cartas limpiar` oculta todo el historial después de confirmar.
- `/cartas restaurar` recupera todas las cartas ocultas.
- El botón C del buzón abre Cartas.
- Leer/Ver carga y archiva el cuerpo que Blizzard exponga.
- Recoger, Responder y Borrar actúan sobre el correo real del buzón.

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

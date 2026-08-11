# Arquitectura de Cartas

## Alcance

Cartas es un addon monolítico de Lua 5.1. `Cartas.lua` contiene persistencia,
adaptación de la API de correo, composición y UI. `Cartas.toc` declara dos
SavedVariables por cuenta: `CartasDB` y el nombre legado `CorrespondenciaDB`.

La instalación auditada es WoW Retail `12.0.7.68974` con interfaz `120007`.

## Almacenes

`mails` contiene enviados confirmados. Cada elemento conserva `owner`,
`ownerRealm`, `recipient`, `sender`, `subject`, `body`, `timestamp`, `date` y
`sequence`.

`archive` contiene recibidos permanentes. Además de cabecera y cuerpo puede
guardar `key`, estado de lectura, dinero, adjuntos, capacidad de respuesta,
`daysLeft` y metadatos privados `_lastInbox*` para asociar una fila viva.

`incoming` es una copia legado. `EnsureArchive` deriva y persiste una clave en
entradas antiguas sin clave, construye un índice de claves ya archivadas y solo
añade las ausentes. Ejecutarla varias veces debe producir el mismo resultado.

`seen` separa el estado visual de lectura de Cartas del estado del buzón.
`deletedArchive` evita reimportaciones legado. Desde 1.9.0 los registros no se
eliminan: `hidden=true` los oculta y Restaurar revierte la marca.

## Captura de enviados

El hook de `SendMail` deja un mensaje pendiente. Solo `MAIL_SEND_SUCCESS` llama a
`SavePendingMail`, por lo que un intento fallido no se considera enviado. Se usa
un único `GetServerTime` para `timestamp` y `date`. No hay poda por cantidad.

La composición aplica los mismos límites declarados por MailFrame de Blizzard:
64 caracteres de asunto y 500 de cuerpo. `SetMaxLetters` evita escribir por
encima del límite y `ValidateOutgoingMailText` actúa como segunda barrera antes
de `SendMail`. `BuildReplySubject` reduce cualquier cadena de respuestas a un
único `RE:`; si un asunto base ocupa 61-64 caracteres, lo conserva sin prefijo
para no truncarlo ni separarlo de su conversación.

## Captura de recibidos

`ScanInbox` toma un reloj común y estima el momento de envío a partir de
`daysLeft` y la caducidad de correo normal o COD. Para cada fila intenta una
asociación uno-a-uno por propietario, remitente, asunto y timestamp. La fila del
buzón es solo desempate porque cambia cuando llega correo nuevo.

El correo normal usa un horizonte de 31 días porque Retail puede devolver
`daysLeft` en el rango `30.x`. Usar 30 genera timestamps futuros y agrupa
visualmente todas las enviadas antes de las recibidas. La estimación limita el
remanente al horizonte para que nunca avance respecto al reloj del escaneo.

`RepairImpossibleFutureTimestamps` migra registros de versiones anteriores solo
cuando `timestamp > _firstSeenAt + 300`. Resta el día introducido por la fórmula
antigua, limita el resultado a la primera observación y conserva los valores
anteriores en `_timestampBeforeExpiryFix` y `_dateBeforeExpiryFix`. Es una
corrección idempotente y no destructiva.

El escaneo solo llama a `GetInboxText` cuando la cabecera ya tiene
`wasRead=true`; solicitar el cuerpo de una carta no leída puede cambiar su estado
en Blizzard. Para una carta pendiente se archiva la cabecera vacía y
`CaptureInboxMail`, ejecutado por Leer/Ver, solicita abrir la fila, reintenta
durante unos seis segundos y completa el registro. Dos mensajes con cuerpo
idéntico no se fusionan solo por esa coincidencia.

## Identidad y límites de la API

Blizzard no entrega un identificador de correo estable. `daysLeft` permite
reconstruir un timestamp aproximado, pero sigue siendo una heurística. Por eso la
política correcta ante ambigüedad es conservar dos registros, no borrar uno.

La cabecera puede archivarse sin abrir el correo. El cuerpo depende de que el
cliente lo haya cargado; Cartas no puede recuperar después el texto de una carta
caducada que nunca se abrió.

## Consulta y presentación

`GetAllCorrespondence` selecciona enviados y recibidos del personaje actual,
omite los marcados `hidden`, crea copias de vista y asigna `person` al interlocutor
real. La UI agrupa por asunto normalizado e interlocutor y ordena cada cadena por
timestamp y secuencia. La profundidad de `RE:` no ordena el hilo porque las
respuestas nuevas normalizan la cadena a un único prefijo.

`BuildParticipantGroups` construye la jerarquía de presentación
interlocutor → conversaciones → cartas. Los interlocutores y sus conversaciones
se ordenan por actividad reciente; las cartas de cada hilo mantienen orden
ascendente. La expansión es estado efímero de la ventana y no escribe en
`CartasDB`. Sin búsqueda, interlocutores y conversaciones empiezan contraídos;
una búsqueda abre sus coincidencias automáticamente. `BUZÓN ACTUAL` es otra
sección desplegable y empieza abierta.

Las filas de `BUZÓN ACTUAL` derivan NUEVA/LEÍDA exclusivamente del `wasRead` de
la cabecera viva. El archivo puede aportar un cuerpo ya conservado, pero su
estado histórico no modifica esa etiqueta. La inicialización llama a `Refresh`
incluso si el frame nace visible y, después, `OnShow` mantiene las reaperturas.

Antes de crear conversaciones, `IsConversationMail` excluye recibidos con
`canReply == false` y mensajes con `isGM == true`. Es la misma clasificación que
usa el buzón vivo para mostrar JUGADOR/SISTEMA. Los registros de Auction House,
Customer Support y demás correo de sistema siguen en `archive` y en BUZÓN ACTUAL;
solo se omiten de los hilos históricos.

La búsqueda divide nombre y reino. `Arian` busca literalmente en la parte de
personaje de `Arianna-ReinoPrueba`; `Arian-Reino` exige también coincidencia
parcial de reino. La entrada no se interpreta como patrón Lua.

`AnalyzeThreadSubject` elimina prefijos `FW:`, `RE:`, cadenas estándar
`RE: RE:` y cadenas irregulares `RE RE:` para obtener el asunto base. También
calcula la profundidad histórica para diagnóstico, pero no decide el orden.
`BuildThreadKey` combina ese asunto base con el interlocutor: reiniciar la cadena
de `RE:` mantiene el hilo, mientras que dos personajes con `RE: Tema principal`
producen dos conversaciones distintas.

## Estrategia de pruebas

`tests/wow_mock.lua` implementa el subconjunto de APIs globales usado al cargar y
persistir. `tests/test_cartas.lua` ejecuta regresiones en Lua 5.1.
`tests/validate_saved_variables.lua` carga un SavedVariables en memoria, toma una
instantánea de campos y confirma que inicialización, migración y lectura no
reducen tablas ni cambian campos previos. La única mutación admitida es la
reparación de timestamp cuando los valores originales quedan preservados en sus
campos de respaldo. Ningún test escribe SavedVariables.

# Memoria del proyecto Cartas

## Objetivo

Cartas simula un historial de correo en World of Warcraft Retail / Midnight.
Guarda enviados que Blizzard no conserva y archiva recibidos aunque desaparezcan
del buzón. La integridad del historial tiene prioridad sobre eliminar duplicados.

## Reglas no negociables de datos

1. Nunca reducir `CartasDB.mails`, `CartasDB.archive` o `CartasDB.incoming` de
   forma automática.
2. Nunca considerar remitente, asunto, cuerpo y tiempo aproximado como prueba
   suficiente para borrar un duplicado. Blizzard no expone un ID persistente.
3. Las migraciones deben ser aditivas, idempotentes y conservar campos
   desconocidos de versiones anteriores.
4. Borrar desde la interfaz es borrado lógico mediante `hidden`; Restaurar debe
   revertirlo. No usar `wipe` ni `table.remove` sobre almacenes de cartas.
5. No volver a introducir límites silenciosos de cantidad o antigüedad.
6. No probar cambios directamente contra el SavedVariables activo. Cargarlo en
   memoria es válido; escribirlo o sustituirlo requiere WoW cerrado y backup.
7. Una carta repetida puede ser legítima. Al asociar cuerpo y cabecera se usa
   timestamp aproximado y fila solo como desempate uno-a-uno.
8. WoW puede devolver `daysLeft` en el rango `30.x` para correo normal. La
   estimación debe usar 31 días y nunca producir un timestamp posterior al reloj
   de observación.

La restricción de WoW cerrado se aplica únicamente a SavedVariables. Los tres
archivos del addon (`Cartas.lua`, `Cartas.toc` y `README.txt`) pueden
sobrescribirse con WoW abierto; después se solicita `/reload` para cargar la
nueva versión. No comprobar ni bloquear una instalación de código por la
presencia del proceso de WoW.

## Modelo persistente

- `CartasDB.mails`: almacén autoritativo de enviados.
- `CartasDB.archive`: almacén autoritativo permanente de recibidos.
- `CartasDB.incoming`: caché legado usada solo para migración y compatibilidad.
- `CartasDB.nextSequence`: secuencia compartida para ordenar/desempatar.
- `CartasDB.seen`: estado de lectura dentro de Cartas.
- `CartasDB.deletedArchive`: supresión legado y soporte de restauración.
- `hidden` y `hiddenAt`: borrado lógico reversible.
- `owner`: personaje propietario, conservado sin reino por compatibilidad.
- `ownerRealm`: reino añadido a registros nuevos sin reescribir los antiguos.

Las SavedVariables declaradas son `CartasDB` y `CorrespondenciaDB`. Esta última
solo existe para migrar el nombre antiguo. Los datos reales viven bajo
`WTF/Account/<cuenta>/SavedVariables/Cartas.lua`, no en la carpeta del addon.

## Flujo de ejecución

- `hooksecurefunc("SendMail", ...)` captura destinatario, asunto y cuerpo.
- `MAIL_SEND_SUCCESS` confirma y añade el enviado; un fallo no debe archivarse.
- `MAIL_INBOX_UPDATE` escanea cabeceras y añade recibidos sin purgar ausentes.
- Un escaneo nunca llama a `GetInboxText` para una cabecera con `wasRead=false`:
  esa llamada puede marcar como leída una carta que el usuario no abrió.
- `GetInboxText` en segundo plano solo se usa si Blizzard ya devuelve
  `wasRead=true`; `CaptureInboxMail` lo usa tras la acción explícita Leer/Ver.
- `CaptureInboxMail` abre/espera una carta solicitada y completa su registro.
- `GetAllCorrespondence` combina enviados y `archive` para el personaje actual.
- `IsConversationMail` excluye del hilo correo no respondible y correo GM, sin
  borrarlo de `archive` ni ocultarlo del buzón vivo.
- La búsqueda compara solo `mail.person`, que es el interlocutor real.

## Búsqueda

No pasar texto parcial del usuario a `Ambiguate`: puede añadir el reino actual.
La consulta se normaliza directamente y usa búsqueda literal parcial sobre el
nombre del personaje. Sin reino, ignora el sufijo de reino; con reino, filtra
ambos componentes. No usar patrones Lua con entrada del usuario.

## Hilos por asunto

`AnalyzeThreadSubject` es la única fuente de verdad para asunto base y
profundidad de respuesta. Debe agrupar, para el mismo interlocutor, asuntos sin
prefijo, `RE:`, cadenas `RE: RE:` y la variante irregular `RE RE:`. Solo se
consume un `RE` sin dos puntos cuando conduce a otro token `RE` que sí termina
en `:`, para no alterar asuntos reales que empiezan por la palabra "Re".

Todos los fixtures versionados deben ser completamente ficticios. No copiar
nombres, asuntos, cuerpos, reinos, cuentas ni rutas obtenidos de un historial
real, aunque parezcan anonimizables.

Al responder, usar siempre `BuildReplySubject`: no concatenar `RE:` directamente.
El asunto debe respetar 64 caracteres y el cuerpo 500, igual que MailFrame en
WoW 12.0.7. Los contadores visuales y `ValidateOutgoingMailText` son defensas
complementarias; no elevar estos límites aunque `SendMail` acepte la llamada.

`BuildThreadChain` debe ordenar cronológicamente por `timestamp` y `sequence`.
No usar la cantidad de `RE:` como orden estructural: `BuildReplySubject` la
reinicia a un único prefijo y una respuesta reciente quedaría fuera de lugar.

`RepairImpossibleFutureTimestamps` corrige únicamente recibidos cuyo timestamp
sea posterior en más de cinco minutos a `_firstSeenAt`, una situación imposible
causada por el horizonte antiguo de 30 días. Antes de cambiarlo debe conservar
los valores en `_timestampBeforeExpiryFix` y `_dateBeforeExpiryFix`. La reparación
es idempotente, no cambia cuerpos ni claves y nunca reduce almacenes.

La vista histórica se construye con `BuildParticipantGroups`: interlocutor,
conversaciones y cartas. Los interlocutores y conversaciones empiezan contraídos
salvo al buscar. `BUZÓN ACTUAL` empieza expandido. El estado desplegado pertenece
a la ventana y nunca se persiste en `CartasDB`.

En `BUZÓN ACTUAL`, `GetInboxHeaderInfo().wasRead` es la única autoridad para
mostrar `[NUEVA]` o `[LEÍDA]`. Un registro de `archive` puede aportar el cuerpo,
pero nunca debe sobrescribir el estado de lectura de una fila viva. La primera
creación de la ventana debe ejecutar `Refresh` explícitamente porque un frame de
WoW puede nacer visible y no disparar `OnShow` al llamar después a `Show()`.

## Pruebas obligatorias

Ejecutar antes de cada release:

`powershell -ExecutionPolicy Bypass -File .\tests\run.ps1`

Ejecutar además contra una copia o mediante carga en memoria del SavedVariables:

`powershell -ExecutionPolicy Bypass -File .\tests\run.ps1 -SavedVariables "RUTA\Cartas.lua"`

Los tests usan Lua 5.1 y mocks de eventos/APIs de WoW. Deben cubrir búsqueda sin
reino, más de 500 enviados, migración idempotente, mensajes idénticos, timestamps
iguales, captura de cuerpo, variantes de `RE`, límites de escritura,
borrado/restauración sin reducción de tablas y estas regresiones de lectura:
un escaneo no solicita cuerpos no leídos, renderizar no cambia `wasRead`, el
estado vivo prevalece sobre `archive`, Leer/Ver sí captura y la ventana refresca
en su primera apertura. Debe existir además una regresión con `daysLeft=30.x`
que intercale una recibida entre dos enviadas, y otra que verifique la reparación
idempotente conservando fecha, timestamp y metadatos originales.

## Flujo de releases e instalación

Los paquetes instalables contienen solo `Cartas/Cartas.lua`,
`Cartas/Cartas.toc` y `Cartas/README.txt`. Los archivos versionados de release,
backups y SavedVariables son privados y nunca se publican.

Procedimiento obligatorio para cada release desde el repositorio canónico:

1. Actualizar la versión en `Cartas.toc` y `README.txt`.
2. Ejecutar `tests/run.ps1` y revisar que no haya fixtures ni rutas reales.
3. Ejecutar `powershell -ExecutionPolicy Bypass -File .\tools\New-CartasRelease.ps1`.
4. El script crea un ZIP versionado privado bajo `Releases/` y sustituye la copia
   raíz `Wow-Midnight-Cartas-Last-Version.zip` con los tres runtime files.
5. Ejecutar `powershell -ExecutionPolicy Bypass -File .\tools\Test-PublicRepository.ps1`.
6. Comprobar `git status`: versionar la nueva copia raíz de Last-Version, nunca
   el ZIP privado de `Releases/`, un backup ni una SavedVariable.
7. Hacer commit y push únicamente de `main`. Verificar el enlace público de
   descarga tras el push y esperar a que CI termine correctamente.
8. Cuando la versión deba publicarse en CurseForge, crear un tag anotado cuyo
   nombre sea `v` seguido exactamente por `## Version` y subir solo ese tag.

`-Label` se reserva para calificadores locales adicionales. `-Force` solo se usa
si se regenera deliberadamente la misma versión. Last-Version se reemplaza en
cada release: no se renombran ni acumulan otros ZIP públicos en Git. Es el único
ZIP que puede seguir Git y nunca debe contener `.git`, tests, documentos de
desarrollo ni SavedVariables.

## Publicación en CurseForge

El proyecto público es `1648457`. `Cartas.toc` debe conservar
`## X-Curse-Project-ID: 1648457`. El workflow `.github/workflows/release.yml`
solo se activa con tags `v*`, vuelve a ejecutar tests y auditoría y publica el
ZIP raíz ya auditado mediante la API oficial. No crear tags mientras el proyecto
de CurseForge siga en revisión.

El tag y `## Version` deben coincidir exactamente: por ejemplo, la versión
`1.9.0-rc8` usa el tag anotado `v1.9.0-rc8`. Tags con `alpha` publican Alpha;
tags con `beta` o `rc` publican Beta; los demás publican Release. No publicar
cada commit y no reutilizar ni mover un tag ya publicado.

El token vive en GitHub únicamente como repository secret `CF_API_KEY`. Nunca
escribir su valor en workflows, commits, `.env`, incidencias o logs. El workflow
solo inyecta el secret en la validación y en el paso de subida. La copia local
privada se gestiona fuera del repositorio. El procedimiento completo está en
`docs/CURSEFORGE.md`.

Para instalar el paquete basta con sobrescribir los tres runtime files en
`Interface/AddOns/Cartas`, aunque WoW esté abierto, y ejecutar `/reload`. Hacer
backup del código anterior sigue siendo recomendable para rollback, pero no se
requiere comprobar ni cerrar el proceso del juego. Nunca aplicar esta regla a
una restauración o sustitución de SavedVariables.

## Limitaciones conocidas

WoW escribe SavedVariables al recargar/cerrar correctamente; un cierre forzado
puede perder cambios de la sesión. Un cuerpo recibido nunca cargado por Blizzard
no puede recuperarse tras caducar. Los metadatos de adjuntos se muestran desde
el buzón vivo, pero el archivo se centra en cabecera y texto de la carta.

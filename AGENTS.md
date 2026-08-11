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
- `GetInboxText` solo se conserva cuando Blizzard ya ha cargado el cuerpo.
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

La vista histórica se construye con `BuildParticipantGroups`: interlocutor,
conversaciones y cartas. Los grupos empiezan contraídos salvo al buscar. El
estado desplegado pertenece a la ventana y nunca se persiste en `CartasDB`.

## Pruebas obligatorias

Ejecutar antes de cada release:

`powershell -ExecutionPolicy Bypass -File .\tests\run.ps1`

Ejecutar además contra una copia o mediante carga en memoria del SavedVariables:

`powershell -ExecutionPolicy Bypass -File .\tests\run.ps1 -SavedVariables "RUTA\Cartas.lua"`

Los tests usan Lua 5.1 y mocks de eventos/APIs de WoW. Deben cubrir búsqueda sin
reino, más de 500 enviados, migración idempotente, mensajes idénticos, timestamps
iguales, captura de cuerpo, variantes de `RE`, límites de escritura y
borrado/restauración sin reducción de tablas.

## Flujo de releases e instalación

Los paquetes instalables contienen solo `Cartas/Cartas.lua`,
`Cartas/Cartas.toc` y `Cartas/README.txt`. Los archivos versionados de release,
backups y SavedVariables son privados y nunca se publican.

Generar un paquete desde el repositorio canónico:

`powershell -ExecutionPolicy Bypass -File .\tools\New-CartasRelease.ps1 -Label ETIQUETA`

Cada release actualiza `Wow-Midnight-Cartas-Last-Version.zip` en la raíz pública.
Es el único ZIP que puede seguir Git y nunca debe contener `.git`, tests,
documentos de desarrollo ni SavedVariables. Antes de publicar, ejecutar
`tools/Test-PublicRepository.ps1`.

## Limitaciones conocidas

WoW escribe SavedVariables al recargar/cerrar correctamente; un cierre forzado
puede perder cambios de la sesión. Un cuerpo recibido nunca cargado por Blizzard
no puede recuperarse tras caducar. Los metadatos de adjuntos se muestran desde
el buzón vivo, pero el archivo se centra en cabecera y texto de la carta.

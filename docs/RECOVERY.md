# Backup, versiones y recuperación

## Separar código e historial

El código del addon vive en `Interface/AddOns/Cartas`. El historial pertenece a
las SavedVariables de la cuenta y vive bajo
`WTF/Account/<cuenta>/SavedVariables/Cartas.lua`.

Actualizar o restaurar el código no requiere sustituir el historial. Nunca se
debe incluir una SavedVariable, un backup ni un dato real del buzón en Git o en
un paquete público.

## Crear el paquete

Desde la raíz del repositorio:

`powershell -ExecutionPolicy Bypass -File .\tools\New-CartasRelease.ps1`

El paquete versionado se guarda en el directorio local ignorado `Releases`. El
script también actualiza `Wow-Midnight-Cartas-Last-Version.zip`, que es el único
ZIP público y contiene únicamente:

- `Cartas/Cartas.lua`
- `Cartas/Cartas.toc`
- `Cartas/README.txt`

Después hay que ejecutar `tools/Test-PublicRepository.ps1`, incluir la copia
raíz Last-Version actualizada en el commit y hacer push de `main`. El ZIP bajo
`Releases`, las SavedVariables y los backups nunca se añaden a Git. `-Label` se
usa solo para un calificador local adicional y `-Force` únicamente al regenerar
de forma deliberada la misma versión.

## Instalar o volver atrás

1. Cerrar WoW por completo.
2. Hacer una copia del directorio activo `Interface/AddOns/Cartas`.
3. Hacer una copia independiente de la SavedVariable actual.
4. Extraer el ZIP sobre `Interface/AddOns`, sobrescribiendo los tres archivos.
5. No tocar `WTF` durante un cambio normal de versión.

## Restaurar datos

1. Cerrar WoW y comprobar que el proceso del juego ya no existe.
2. Hacer otra copia del fichero actual, aunque parezca dañado.
3. Copiar el backup elegido como
   `WTF/Account/<cuenta>/SavedVariables/Cartas.lua`.
4. Abrir WoW y comprobar `/cartas` antes de enviar o eliminar correo nuevo.

No sustituir SavedVariables con el juego abierto: WoW mantiene la tabla en
memoria y puede sobrescribir el fichero restaurado al cerrar o usar `/reload`.

## Validación no destructiva

Este comando carga una SavedVariable en un proceso Lua independiente y no
escribe el fichero:

`powershell -ExecutionPolicy Bypass -File .\tests\run.ps1 -SavedVariables "RUTA\Cartas.lua"`

No usar una ruta real en documentación, fixtures, commits ni incidencias
públicas.

# Cartas

Addon para World of Warcraft Retail / Midnight que conserva las cartas enviadas
y recibidas y las presenta como conversaciones agrupadas por interlocutor.

## Descargar

[Descargar la última versión](https://github.com/ivandod/cartas/raw/refs/heads/main/Wow-Midnight-Cartas-Last-Version.zip)

El ZIP contiene una única carpeta `Cartas` con los tres archivos necesarios para
ejecutar el addon.

## Instalar

1. Cierra World of Warcraft.
2. Extrae el ZIP dentro de `Interface/AddOns`.
3. Confirma que exista `Interface/AddOns/Cartas/Cartas.toc`.
4. Inicia el juego y comprueba que Cartas esté habilitado.

Actualizar el addon no requiere reemplazar las SavedVariables ni el historial.

## Privacidad

Este repositorio contiene únicamente código, documentación y fixtures ficticios.
No incluye historiales de correo, SavedVariables, backups, rutas de cuentas ni
paquetes de versiones privadas.

## Desarrollo

Los tests usan Lua 5.1:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run.ps1
```

Antes de publicar:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\New-CartasRelease.ps1
powershell -ExecutionPolicy Bypass -File .\tools\Test-PublicRepository.ps1
```

El primer comando guarda el paquete versionado en `Releases/` (ignorado por
Git) y reemplaza `Wow-Midnight-Cartas-Last-Version.zip`. En cada release hay que
incluir en el commit esa copia raíz actualizada; nunca se publican los ZIP
versionados, backups ni SavedVariables. El flujo completo está en `AGENTS.md`.

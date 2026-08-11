# Publicación automática en CurseForge

## Configuración

- Proyecto CurseForge: `1648457`.
- Workflow: `.github/workflows/release.yml`.
- Paquete publicado: `Wow-Midnight-Cartas-Last-Version.zip`.
- Secret requerido en GitHub Actions: `CF_API_KEY`.

El secret se crea una sola vez en el repositorio de GitHub desde
`Settings → Secrets and variables → Actions → New repository secret`. Su valor
nunca se añade al repositorio. Mientras el proyecto de CurseForge esté en
revisión no se debe crear ningún tag de publicación.

## Crear una publicación

1. Actualizar `## Version` en `Cartas.toc` y la versión de `README.txt`.
2. Ejecutar los tests y generar `Wow-Midnight-Cartas-Last-Version.zip`.
3. Ejecutar `tools/Test-PublicRepository.ps1`.
4. Hacer commit y push de `main`; esperar a que CI termine correctamente.
5. Crear un tag anotado que coincida exactamente con la versión:

   `git tag -a v1.9.0-rc8 -m "Cartas 1.9.0-rc8"`

6. Subir el tag:

   `git push origin v1.9.0-rc8`

El workflow repite tests y auditoría, valida que el ZIP contenga solo los tres
runtime files y lo sube mediante la API oficial. No se debe volver a ejecutar
una publicación que ya terminó correctamente porque CurseForge trata cada
subida como un archivo nuevo.

## Tipo de archivo

- Un tag que contiene `alpha` se publica como Alpha.
- Un tag que contiene `beta` o `rc` se publica como Beta.
- Cualquier otra versión se publica como Release.

`tools/Publish-CurseForge.ps1` obtiene la versión compatible de WoW a partir de
`## Interface`, genera el changelog desde el tag anterior y exige que el tag sea
igual a `v<Version>`. El modo `-DryRun` valida toda la configuración sin usar el
token ni contactar con el endpoint de subida.

## Seguridad

El historial de correo, SavedVariables, backups y paquetes privados nunca se
publican. El workflow sube el ZIP raíz que ya valida
`tools/Test-PublicRepository.ps1`; no reconstruye el paquete desde todo el árbol
Git. El secret solo está disponible en los pasos de validación y publicación.

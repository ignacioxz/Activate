# Activate

App nativa de iPhone (Swift / SwiftUI, iOS 27, Xcode 27.1) de **pausas activas verificadas por sensores** para operadores de camión de extracción en faenas mineras (caso "Marco": turno 7×7, dolor lumbar, sin señal en el rajo).

- **No falseable**: cada actividad se verifica con sensores en vivo (podómetro, cámara frontal con Vision, ARKit Face Tracking, test Stroop) y la sesión queda firmada en el Secure Enclave del teléfono.
- **IA local**: Foundation Models (Apple Intelligence on-device) orquesta la pausa, lee las estadísticas y redacta la hoja para el kinesiólogo. Nada sale del teléfono.
- **Check-in** con el Cuestionario Roland-Morris chileno abreviado (6 ítems Sí/No; Guic, Galdames y Rebolledo, Rev Med Chile 2014).
- **Gamificación** estilo Duolingo adaptada al 7×7: racha por día laboral, "Doblete" al segundo día seguido, "Tiro limpio" al completar el turno.
- **Diseño** flat + Liquid Glass; feedback visual grande y háptico (sin voz: en la mina hay ruido).

## Requisitos

- Xcode 27.1 o superior, iOS 27.0.
- Dispositivo físico para sensores (cámara, ARKit, podómetro no existen en el simulador); iPhone con Apple Intelligence (15 Pro o posterior) para el coach con IA; sin IA la app funciona completa con reglas.

## Cómo empezar

1. Clona el repositorio y abre `Activate.xcodeproj` en Xcode.
2. Selecciona el iPhone (o el simulador para la UI) y ejecuta con `⌘R`.
3. Desde terminal: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Activate.xcodeproj -scheme Activate -destination 'platform=iOS Simulator,name=iPhone 17' build`

## Estructura

| Ruta | Descripción |
| --- | --- |
| `Activate/` | Código fuente (carpeta sincronizada con el target) |
| `docs/PLAN.md` | Plan de producto y arquitectura |

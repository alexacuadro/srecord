# Historial de Conversación - Proyecto S-RECORD

## Registro de Decisiones Lógicas y Evolución Técnica (PTE-Milenium)

### Fase 1: Arquitectura Base y Pantallas Autónomas
- **Decisión**: Implementación de arquitectura de pantallas independientes en `lib/screens/`.
- **Archivos Creados**:
    - `login_screen.dart`: Gestión de acceso con enrutamiento simplificado (Password 'L' para Lista, 'B' para Banco).
    - `lista_screen.dart`: Visualización de registros dinámicos.
    - `bote_screen.dart`: Control de flujo de datos/ahorros.
    - `banco_screen.dart`: Gestión de nodos/cuentas.
- **Estado**: Uso de `ValueNotifier` para reactividad ligera sin dependencias externas pesadas.

### Fase 2: Identidad Visual e Iconografía
- **Icono**: Integración de `assets/logo.png` como icono oficial.
- **Configuración**: Uso de `flutter_launcher_icons` para generación automatizada en Android.

### Fase 3: Estándar de Compilación (Build Maestro)
- **Configuración de APK**:
    - `minSdkVersion`: 21 (Compatibilidad Android 5.0+).
    - `targetSdkVersion`: 35.
    - `extractNativeLibs`: true.
- **Optimización**: Activación de *Tree Shaking* de iconos.
- **Resultado**: Generación de `srecord_v1_Unified.apk` (21.3 MB) en la raíz del proyecto.

### Fase 5: Optimización de Pantalla y Modo Inmersivo
- **Modo Pantalla Completa**: Se configuró `SystemUiMode.immersiveSticky` en `main.dart` para ocultar barras de sistema.
- **Orientación**: Bloqueo forzado a modo Vertical (`portraitUp`).

### Fase 6: Formalización de Estándares (PTE-Milenium)
- **Marco de Trabajo**: Adopción oficial del **Protocolo de Trabajo Estándar (PTE-Milenium)**.
- **Refinamiento de UI**: Unificación del esquema de colores basado en `Colors.lightBlue`.
- **Ajustes de Alineación Ergonómica**:
    - **Sincronización de Tabla**: Márgenes unificados a 4 px.
    - **Ancho de Columna**: Aumento del ancho relativo de la columna **BOLA** (flex 14 vs 10) para facilitar la lectura de jugadas complejas (Fijo/Corrido).
- **Compactación de Registros**:
    - **Historial**: Reducción de fuente a 14 y padding a 2 px para mayor densidad de datos.
    - **Visor**: Reducción de altura y reubicación del botón **DEL** al lateral derecho.
- **Evolución del Teclado**:
    - **Estrechamiento**: Compactación hacia la izquierda (margen derecho 110 px).
    - **Lógica de Bolita**: Soporte para apuestas Fijo/Corrido mediante doble paréntesis `( )` e inserción automática.
    - **Botón AL (Rango)**: Evolución del botón AL para actuar como expansor de rangos. Al ingresar `01 AL 09`, el visor genera automáticamente la serie `01-02-03-04-05-06-07-08-09`.
    - **Scroll Independiente**: Se habilitó el desplazamiento por columna, permitiendo navegar en BOLA, PARLE o CENTENA de forma autónoma.
    - **Ajuste Ergonómico de Visor**: El visor se desplazó hacia el borde izquierdo (margen de 5 px) para una alineación más natural con los números de registro.
    - **Compactación de Teclado**: Se aumentó el `childAspectRatio` a 1.6 y se redujo la altura del botón especial `( )` a 100 px para optimizar el espacio vertical.
- **Seguridad y Navegación**:
    - Implementación de un **Menú Lateral (Drawer)** para acceso a secciones públicas: **Mis Partes**, **Números Limitados**, **Premios** y **Bote**.
    - **Restricción de Acceso a BANCO**: Se eliminó del menú lateral. Ahora es una sección restringida accesible únicamente mediante contraseña específica desde el Login para garantizar la integridad de los nodos.
    - Eliminación del icono de ahorros (cerdito) de la barra superior para simplificar la UI.

- **Cálculo de Totales Dinámicos**:
    - Implementación de un panel de sumatorias encima del botón `( )`.
    - **B (Bola), P (Parle), C (Centena):** Sumas individuales actualizadas en tiempo real.
    - **L (Limpio):** Cálculo del neto total aplicando un descuento del 20% (comisión).
- **Indicadores de Balance y Premios**:
    - Se añadió la fila **Premio P:** para rastrear los pagos de premios.
    - Implementación de lógica de balance: **Gana** si el balance es negativo (Limpio - Premios < 0) y **Pierde** si es positivo, con colores verde/rojo respectivamente.
    - El panel de totales se reubicó permanentemente sobre el botón especial `( )` en el lateral derecho para una visualización compacta y profesional.
    - **Lógica de Colores de Balance**: Se ajustó la señalética cromática: los valores positivos se muestran en **Verde** y los negativos en **Rojo**, independientemente de la etiqueta (Gana/Pierde).
- **Validaciones de Apuesta y Simbología**:
    - **Dinero Obligatorio**: Se estableció la obligatoriedad de asignar dinero a cada jugada; de lo contrario, el sistema bloquea el registro.
    - **Simbología "X" (Restringida)**: La conversión de valor 0 a **(X)** ahora es exclusiva para la columna **BOLA**. En **PARLE** y **CENTENA**, el sistema bloquea activamente el registro si el monto es 0, exigiendo una cifra válida.
    - **Refuerzo en BOLA**: Se ajustó la validación para BOLA; ahora es obligatorio que al menos una de las apuestas (Fijo, Corrido o ambas) tenga un valor mayor a 0. Se prohíbe el registro si todos los montos son 0.
- **Funciones de Teclado Avanzadas**:
    - **Series por Pulsación Larga**: Implementación de atajos en los botones 0-9. Al mantener presionado un número, se despliega un menú inferior para generar automáticamente la serie de **Terminales** (ej. 01, 11, 21...) o **Comensales** (ej. 10, 11, 12...) del dígito seleccionado. Compatible con los formatos de 2 y 3 dígitos.
- **Gestión de Historial y Foco**:
    - **Ubicación Automática**: Al registrar una jugada, el sistema posiciona automáticamente el scroll de la columna correspondiente en la parte superior (donde se insertan los nuevos datos) para garantizar visibilidad inmediata.
    - **Resaltado Dinámico**: La última jugada ingresada (o el bloque de jugadas en caso de series) se resalta con un fondo **Ámbar suave** y un borde diferenciado, permitiendo al usuario identificar rápidamente su última acción. El resaltado se actualiza con cada nuevo registro.
- **Limpieza de Banco**:
    - Se vació el contenido de la pantalla **Banco** para una futura reestructuración total bajo los nuevos requerimientos de red.
- **Expansión del Módulo de Banco (Administración)**:
    - **Estructura de Panel Único**: Se consolidaron las secciones `Colecturía`, `Crear Listas`, `Gestión`, `Números más jugados`, `Números a Limitar`, `Partes de Listeros`, `Planes` y `Tiro Oficial` dentro de `BancoScreen` como vistas dinámicas.
    - **Implementación de Planes (Ajuste de Plan)**:
        - Interfaz funcional basada en el esquema de la banca: Selector de planes con opciones de agregar/eliminar.
        - Segmentación por categorías: **Porcientos del Banco**, **Pagos** y **Topes de Recogida** (todos con división Lista/Bote).
        - Diseño visual ergonómico con códigos de colores por sección.
        - **Persistencia Atómica**: Integración de `SharedPreferences` para el guardado local automático de todos los planes y sus valores.
    - **Reorganización de Menú**: Se priorizaron las opciones de `Colecturía`, `Crear Listas` y `Gestión` en la parte superior.
- **Sistema de Listeros y Anclaje de Seguridad**:
    - **Crear Listas**: Nueva interfaz en el panel del Banco para que el administrador cree perfiles de Listeros con nombre y contraseña de 4 dígitos.
    - **Identidad en Sesión**: La aplicación ahora identifica qué Listero ha iniciado sesión y muestra su nombre en el panel principal (`ListaScreen`).
    - **Anclaje de Dispositivo (Device Binding)**: Se implementó una lógica de seguridad donde el primer inicio de sesión con una contraseña de Listero ancla permanentemente el dispositivo a ese perfil. Ningún otro Listero puede acceder en ese dispositivo, reforzando la exclusividad y control de las listas.
    - **Persistencia de Usuarios**: Los perfiles de los listeros se guardan de forma segura en el almacenamiento local.
- **Seguridad Avanzada y Control del Banco**:
    - **Contraseña Maestra**: Actualizada a `Sonya002215` para acceso administrativo. Se eliminó el acceso genérico 'L'.
    - **Persistencia con Base de Datos Local**:
        - Implementación de `SQLite` mediante el paquete `sqflite`.
        - Creación de `DatabaseHelper` para la gestión estructurada de registros (BOLA, PARLE, CENTENA).
        - Los datos ahora persisten permanentemente en el dispositivo, incluso tras cerrar o reiniciar la aplicación.
    - **Control de Acceso y Bloqueo**:
        - El Banco puede bloquear instantáneamente a cualquier listero.
        - Soporte para desvincular dispositivos y PINs (Unbind).
        - Visualización de PINs de listeros en el panel administrativo.
        - Obligatoriedad de asignar un Plan al crear una nueva lista.
- **Evolución del Motor de Cálculos y Colecturía**:
    - **Cálculos Dinámicos por Plan**: El panel del Listero ahora aplica automáticamente los porcentajes de descuento (BOLA, CENTENA, PARLE) definidos en el **Plan** específico asignado por el Banco.
    - **Panel de Colecturía General**: Implementación de una vista consolidada para el administrador que muestra el rendimiento bruto de todos los listeros, desglosado por tipo de jugada.
    - **Módulo de Gestión**: Añadidas herramientas de mantenimiento para limpiar registros o restablecer completamente la aplicación de fábrica.
    - **Consolidación Maestra**: Contraseña de banco actualizada a `Sonya002215` y eliminación definitiva del acceso genérico 'L'.

---
*Última actualización: Implementación de cálculos dinámicos por plan y Colecturía General.*

### Fase 7: Protocolo de Desglose de Parles (MileniumPro)
- **Lógica de Desglose Atómico**: Implementación del sistema para fragmentar Parles en pares de dos números si se detecta un "choque" (dinero acumulado previo en cualquier sub-combinación).
- **Validación Combinatoria de Topes**: 
    - Se refinó la función `_getAcumulado` para calcular el peso real de un par dentro de una jugada combinada usando combinatoria $\binom{n}{2}$ y producto de frecuencias.
    - Soporte total para números repetidos (ej. `22-12-22-23`) garantizando que cada instancia cuente de forma independiente.
- **Llenado de Copa (Automatizado)**:
    - Las jugadas que exceden el tope de la Lista se fragmentan; la parte permitida permanece en la Lista y el sobrante se desvía al Bote.
    - Si el Bote también está lleno, el excedente final se descarta y se notifica al usuario mediante un diálogo de "EXCESO BOTADO".
- **Preservación de Integridad Visual**:
    - Se eliminaron sufijos informativos del campo `valor` en la base de datos para evitar truncamientos visuales ("E...").
    - **Respeto al Orden del Listero**: Se desactivó el ordenamiento automático de números; el sistema guarda y muestra la jugada en la secuencia exacta de entrada.
- **Punto de Restauración**: Creación del checkpoint global en `backups/fase_parles_desglose_v1/`.

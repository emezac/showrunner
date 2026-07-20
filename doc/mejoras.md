**Guía Maestra para Crear una App de Escritura y Preproducción de Cortometrajes impulsada por IA**

Para crear una aplicación excepcional enfocada en cortometrajes, tomaremos los principios fundamentales, la arquitectura de plantillas y los flujos de trabajo automatizados de StoryHacker OS y los adaptaremos al formato de guionismo y cine. 

Esta es la guía ultradetallada para desarrollar tu aplicación:

### Fase 1: Arquitectura Base y Gestión de Proyectos
En lugar de libros, tu aplicación debe estructurarse en torno a proyectos audiovisuales.
*   **Gestión de Proyectos Individuales:** Cada proyecto representará un cortometraje único. Al crear un nuevo proyecto, el usuario deberá seleccionar el género cinematográfico, ingresar el título, la idea central y la audiencia objetivo.
*   **El Documento "Brain Dump" (Descarga de Ideas):** El núcleo inicial de cada proyecto debe ser un documento en blanco diseñado para que el usuario escriba todo lo que se le ocurra sobre su idea de manera desestructurada. Este documento será vital para alimentar las automatizaciones posteriores.

### Fase 2: El Motor de la App - Plantillas (Templates) y Guías de Género
El mayor diferenciador de tu app será el uso de marcos de trabajo (frameworks) y plantillas, ya que la IA funciona mejor cuando tiene una estructura sólida sobre la cual construir, evitando así resultados genéricos.
*   **Guías por Subgéneros Cinematográficos:** Crea plantillas altamente específicas (ej. Thriller Psicológico, Comedia de Terror, Ciencia Ficción Íntima). Cada subgénero debe incluir guías estructuradas pre-programadas:
    *   **Fichas de Personajes (Character Sheets):** Arquetipos comunes del género.
    *   **Guía de Trama/Escaleta (Plot Guide):** Estructuras narrativas escena por escena, lo suficientemente vagas para permitir creatividad pero adaptadas al ritmo del género.
    *   **Guías de Tropología (Tropes Guide):** Elementos recurrentes y expectativas de la audiencia (ej. "pez fuera del agua", "familia encontrada").
    *   **Guías de Mundo/Locaciones y Estilo Visual.**
*   **Plantillas según la Duración del Corto:** Así como StoryHacker tiene adaptaciones para novelas, novelas cortas o cuentos, tu app debe tener guías de trama ajustadas a tiempos cinematográficos: Micro-cortos (1-3 min), Cortos estándar (5-15 min) y Mediometrajes (20-40 min).
*   **Constructor de Plantillas Personalizadas:** Permite a los usuarios interactuar con un bot experto para crear sus propias plantillas de tropos o tramas combinando géneros (ej. un misterio histórico de los años 50), o construir guías desde cero.

### Fase 3: Flujos de Trabajo Automatizados (El "Short Film Builder")
Debes programar un sistema de automatizaciones paso a paso (hardcoded) para estructurar el cortometraje progresivamente.
*   **De "Brain Dump" a Dossier (Tratamiento):** La IA debe leer el documento de ideas inicial, extraer el mejor concepto (pitch), y construir un dossier que incluya: sinopsis, elenco principal y secundario, elementos clave del mundo y latidos narrativos.
    *   **Filtros de Calidad Automatizados:** Añade pasos donde la IA aplique una *crítica emocional* (para asegurar un impacto en la audiencia), una *crítica de nombres de personajes* (para evitar nombres que suenen demasiado generados por IA), y una *crítica de lógica* (para asegurar que las reglas del mundo tengan sentido), reescribiendo el dossier basándose en estas evaluaciones.
*   **De Dossier a Personajes y Locaciones:** Una automatización que identifique a los personajes en el dossier y expanda sus perfiles (descripción física, peculiaridades, estilo de diálogo y arco de personaje) ejecutando verificaciones de coherencia contra la idea original.
*   **Generador de Escaleta (Outline):** Utiliza los personajes, el mundo y las *plantillas de trama del género* seleccionadas para generar una estructura narrativa (beat sheet) detallada que respete los tropos esperados por la audiencia.
*   **Generador de Guion (Escena por Escena):** Para evitar la "deriva narrativa" (narrative drift) donde la IA pierde el hilo, la generación del guion debe hacerse escena por escena o máximo en bloques de tres escenas. La IA debe leer la escena inmediatamente anterior para mantener la continuidad, el formato de guion y el estilo del usuario.

### Fase 4: Asistentes Contextuales por IA (Personas)
Implementa un panel lateral de chat que sea el copiloto del cineasta.
*   **Contexto Inyectado:** El chat debe poder "leer" automáticamente el documento actual, los perfiles de personajes, la escaleta, y todas las guías del género seleccionado.
*   **Personas (Roles) Especializados:** Crea instrucciones del sistema (system prompts) específicas para diferentes tareas. Ejemplos:
    *   *Asistente de Lluvia de Ideas:* Para rebotar conceptos iniciales (ej. "Dame 5 ideas de premisas" y refinar iterativamente).
    *   *Asistente de Personajes:* Para profundizar en la psicología de un rol.
    *   *Asistente de Dirección/Cinematografía:* (Adaptación sugerida para cortos) Para visualizar ángulos de cámara o paletas de colores basados en la escena actual.
*   **Personas Personalizadas:** Permite que los usuarios creen sus propios asistentes definiendo el nombre, descripción y el "system prompt" en la configuración.

### Fase 5: Interfaz de Escritura Dinámica
*   **Generación en línea (Comando de acceso rápido):** Implementa un atajo (como Control+K) dentro del documento principal. El usuario describe lo que quiere generar (ej. "Escribe la escena de apertura con María llegando a la estación de policía"), selecciona el contexto que la IA debe leer (perfil de María, la escaleta), y la IA redacta directamente en la página.
*   **Edición Asistida (AI Edit):** Permite al usuario sombrear un texto específico y pedirle a la IA modificaciones puntuales, como "haz el diálogo más conciso", "haz la acción más tensa", y ofrecer la opción de aceptar o rechazar los cambios.
*   **Mapa de Relaciones:** Un panel visual interactivo que rastree cómo cada personaje se relaciona con los demás; esta información alimentará el contexto de la IA al escribir diálogos interactivos.

### Fase 6: Arquitectura Técnica y Modelo de Negocio
*   **Conexión de IA vía API (Pay-as-you-go):** Para mantener los costos operativos bajos y no quebrar, no incluyas el uso ilimitado de IA en la suscripción base. Permite que los usuarios conecten su propia clave API (a través de plataformas como OpenRouter) para que paguen solo por los tokens que consumen al utilizar modelos avanzados como Claude (que destacan en escritura creativa).
*   **Selector de Modelos por Defecto:** Da la opción al usuario de configurar qué modelo de IA quiere usar por defecto para el chat y para las generaciones en línea.
*   **Almacenamiento:** Utiliza un sistema basado en la nube para guardar automáticamente todos los documentos, escaletas y guiones dentro de los proyectos.

### Fase 7: Plan a Futuro (Roadmap)
Para escalar la aplicación tras el lanzamiento, considera incorporar:
*   **Modo de Edición Avanzada (Agentes):** Un sistema que, una vez terminado el guion, utilice flujos de trabajo de agentes autónomos (Agentic Flow) para hacer revisión ortográfica, corrección de formato de guion, pruebas de lectura (simulando beta readers) y eliminación de frases típicas de la IA.
*   **Constructor de Webseries:** Un sistema de alto nivel que planifique el arco narrativo completo de una miniserie, creando un contexto unificado de personajes y mundo antes de generar los guiones de los episodios individuales.

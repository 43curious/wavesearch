# WaveSearch explicado de forma muy sencilla

## La idea en una frase

**WaveSearch es un buscador de sonidos para Mac.**

Sirve para encontrar rápidamente un sonido guardado en el ordenador, escucharlo y llevarlo a un proyecto de vídeo, música, pódcast o videojuego.

---

## Imagina una caja enorme de sonidos

Imagina que tienes miles de cajas con sonidos dentro:

- una puerta cerrándose;
- un perro ladrando;
- lluvia;
- una explosión;
- pasos;
- el motor de un coche;
- un golpe de tambor.

Buscar uno abriendo las cajas una por una sería muy lento.

WaveSearch funciona como un **bibliotecario de sonidos**. Primero mira qué sonidos tienes y prepara una lista ordenada. Después puedes escribir algo como `lluvia`, `golpe` o `coche` para encontrarlo sin recorrer todas las carpetas a mano.

> WaveSearch no crea los sonidos. Ayuda a encontrar y utilizar los que ya están guardados en tus carpetas y discos.

---

## Un ejemplo para explicárselo a un niño

Supongamos que estamos haciendo un vídeo de un dragón.

Necesitamos:

1. Un rugido.
2. El sonido de unas alas.
3. Una llamarada.
4. Un golpe fuerte cuando el dragón aterriza.

Sin WaveSearch tendríamos que abrir muchas carpetas y escuchar muchos archivos hasta encontrar los adecuados.

Con WaveSearch podemos:

1. Escribir una palabra como `rugido`.
2. Ver una lista de posibles sonidos.
3. Escucharlos con un botón.
4. Elegir el que más nos guste.
5. Arrastrarlo al programa donde estamos montando el vídeo.

Es parecido a buscar una canción en una aplicación de música, pero aquí se buscan **efectos de sonido guardados en el Mac**.

---

## ¿Cómo funciona?

### 1. Le enseñamos dónde están los sonidos

La persona elige una carpeta del Mac o de un disco externo. Esa carpeta puede contener muchas subcarpetas y archivos de audio.

A cada carpeta añadida la llamamos una **biblioteca**.

### 2. WaveSearch prepara un catálogo

El programa revisa los archivos y apunta datos útiles, por ejemplo:

- el nombre del sonido;
- dónde está guardado;
- cuánto dura;
- si es mono o estéreo;
- algunos datos escritos dentro del propio archivo.

Este proceso se llama **indexar**. Es como hacer el índice de un libro para encontrar rápidamente cada tema.

### 3. Escribimos lo que queremos encontrar

Podemos buscar palabras como:

- `rain`;
- `door`;
- `impact`;
- `whoosh`.

También se puede pedir una duración concreta. Por ejemplo:

- `whoosh <2s`: sonidos de tipo *whoosh* que duren menos de 2 segundos;
- `riser >5s`: sonidos de tipo *riser* que duren más de 5 segundos.

Muchos archivos profesionales usan nombres en inglés, por eso algunos ejemplos aparecen en ese idioma.

### 4. Escuchamos los resultados

Al elegir un resultado, WaveSearch permite reproducirlo antes de usarlo.

También muestra su **forma de onda**, un dibujo que representa el sonido:

- las zonas grandes suelen ser más fuertes;
- las zonas pequeñas suelen ser más silenciosas;
- la línea que avanza indica qué parte estamos escuchando.

### 5. Usamos el sonido

Se puede arrastrar el archivo completo a otra aplicación. También se puede seleccionar solo una parte útil del sonido y arrastrar ese fragmento.

Por ejemplo, si un archivo dura diez segundos pero solo necesitamos el golpe del segundo cuatro, podemos escoger esa parte.

---

## Las partes principales de la pantalla

### Barra lateral

Muestra las carpetas o bibliotecas de sonidos que hemos añadido.

Si un disco externo está desconectado, WaveSearch avisa de que falta. Los nombres siguen apareciendo en el catálogo, aunque será necesario conectar el disco para reproducir esos archivos.

### Buscador

Es el lugar donde escribimos el tipo de sonido que queremos encontrar.

### Lista de resultados

Muestra los sonidos encontrados y algunos datos, como su duración y ubicación.

### Reproductor

Permite escuchar, pausar, cambiar el volumen y saltar a otra parte del sonido.

### Forma de onda

Es el dibujo del audio. Sirve para ver dónde empieza un golpe, dónde hay silencio o qué fragmento queremos seleccionar.

---

## Funciones un poco más inteligentes

### Buscar sonidos parecidos

Podemos elegir un sonido y pedirle al programa que encuentre otros que se le parezcan.

Es como enseñarle el maullido de un gato y decirle: **“Busca sonidos similares a este”**.

Para hacerlo, WaveSearch crea una especie de huella del audio. No es una huella real: es un conjunto de números que describe algunas características del sonido y permite compararlo con otros.

### Buscar por significado

Existe una función opcional que intenta comprender la idea de una búsqueda, no solo las letras del nombre del archivo.

Por ejemplo, puede intentar relacionar palabras y sonidos con conceptos parecidos aunque no tengan exactamente el mismo nombre.

Esta función necesita instalar componentes adicionales, ocupa bastante espacio y trabaja de forma local. La búsqueda normal continúa funcionando sin ella.

---

## ¿Dónde guarda la información?

WaveSearch crea un catálogo en el propio Mac. Ese catálogo contiene información para localizar los archivos rápidamente.

Los sonidos originales permanecen en sus carpetas. El programa no necesita moverlos ni subir la biblioteca a Internet para realizar la búsqueda normal.

---

## ¿Para quién puede ser útil?

WaveSearch puede ayudar a:

- editores de vídeo;
- diseñadores de sonido;
- creadores de videojuegos;
- músicos;
- personas que hacen pódcast;
- cualquiera que tenga muchos efectos de sonido.

No es un programa completo para montar películas o crear canciones. Su tarea principal es **encontrar, escuchar, escoger y entregar sonidos a otros programas**.

---

## Palabras difíciles traducidas a lenguaje cotidiano

| Palabra | Explicación sencilla |
|---|---|
| Archivo de audio | Un sonido guardado en el ordenador. |
| Biblioteca | Una carpeta o colección de sonidos. |
| Indexar | Preparar una lista para poder buscar muy rápido. |
| Base de datos | El cuaderno ordenado donde el programa guarda su catálogo. |
| Forma de onda | El dibujo que representa cómo cambia un sonido con el tiempo. |
| Metadatos | Información que acompaña al archivo, como su nombre o descripción. |
| Búsqueda acústica | Comparar cómo suenan los audios para encontrar otros parecidos. |
| Búsqueda semántica | Intentar buscar por la idea o el significado de las palabras. |
| Local | Que el trabajo se realiza en el propio ordenador. |

---

## ¿Cómo está construido? — versión sencilla

WaveSearch tiene dos grandes partes:

1. **La parte visible**, hecha para macOS: contiene las ventanas, los botones, las listas y el reproductor.
2. **El motor interno**: recorre las carpetas, organiza el catálogo, busca los nombres y compara sonidos.

Es parecido a un coche:

- el volante, los pedales y el tablero son la parte visible;
- el motor es la parte que hace el trabajo por dentro.

La parte visible está creada principalmente con **Swift y SwiftUI**. El motor está escrito principalmente en **Zig** y usa **SQLite** como su cuaderno ordenado. No hace falta conocer estas tecnologías para utilizar el programa.

---

## Resumen para contarlo en 20 segundos

> “WaveSearch es como Google, pero para los efectos de sonido que tienes guardados en tu Mac. Le das una carpeta, prepara un catálogo y después puedes escribir qué sonido buscas, escucharlo y arrastrarlo a un vídeo, una canción o un juego. También puede encontrar sonidos parecidos y enseñarte su forma.”

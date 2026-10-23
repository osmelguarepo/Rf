# Fuel Rivals: características del juego

Lista de lo que el juego hace hoy, según el código del repositorio (`scripts/`, `project.godot`, `docs/`). No incluye
nada que no esté implementado; lo que falta o no está verificado se dice en la última sección.

Formato: **Característica** y, debajo, **Cómo**.

---

## Sección 1. Modos de juego

1. **El juego tiene dos modos: LOCAL y ONLINE.**
   - 1.1 Cómo: en la pantalla de título se elige con Arriba/Abajo (flechas, W/S, cruceta o palanca izquierda) y se confirma
     con Enter, Espacio, A o Start. También sirve un clic o toque sobre la opción.
   - 1.2 **LOCAL** funciona hoy: humanos en la misma pantalla, y bots en los puestos vacíos.
   - 1.3 **ONLINE** (solo humanos) todavía no está construido: aparece como "COMING SOON" y no se puede iniciar.

2. **LOCAL: hasta 6 autos en una sola pantalla, con una partida al mejor de 3 rondas.**
   - 2.1 Cómo: cada persona se une con su mando (A) o, si juega sola, con el teclado (Enter). Gana la partida el primero en
     llegar a 2 rondas ganadas.
   - 2.2 El antiguo juego de un jugador por etapas (metas de 13 500, 15 750, 18 000 y 20 250 px, con el tanque lleno en cada
     etapa) ya no está en el menú; su código y sus pruebas siguen en el repositorio.

3. **LOCAL: empate y resultados.**
   - 3.2 Con 3 o más jugadores puede haber empate 1-1-1: tras 5 rondas gana quien tenga más rondas, luego más puntos totales y
     luego más distancia. Si siguen iguales, nadie gana.
   - 3.3 Con un solo jugador, la partida termina al ganar 2 rondas o al no ganar 2.

4. **Los bots rellenan automáticamente todos los puestos vacíos.**
   - 4.1 Cómo: no hay selector. Con un humano hay 5 bots, con dos humanos 4, y así hasta 6 autos en total. Cuando alguien se
     une, un bot le cede el puesto; si se va, el bot vuelve.
   - 4.2 Los bots aceleran siempre, pasan a marcha alta desde 160 km/h si hay 150 px libres delante, buscan el carril vecino más
     despejado, corrigen los derrapes, persiguen los autos arcoíris y reaccionan con 12 pasos de retraso.
   - 4.3 Los bots nunca ganan una ronda ni la partida.

---

## Sección 2. Movimiento y conducción

5. **El jugador 1 puede moverse a izquierda y derecha.**
   - 5.1 Cómo: teclado, flechas Izquierda/Derecha o A/D. Mando: cruceta o palanca izquierda (pasando de la mitad del recorrido).

6. **El coche acelera.**
   - 6.1 Cómo: teclado, Arriba, W o Z. Mando, B, cruceta arriba o palanca arriba.

7. **El coche tiene dos marchas; la alta solo funciona mientras se mantiene pulsada.**
   - 7.1 Cómo: mantener X (teclado) o A (mando) junto con el acelerador.
   - 7.2 Marcha baja: hasta 198 km/h, ganando 70 km/h por segundo. Marcha alta: hasta 400 km/h, ganando 15 km/h por segundo
     por debajo de 160 km/h y 45 por encima.

8. **El coche frena.**
   - 8.1 Cómo: teclado, Abajo o S. Mando, cruceta abajo o palanca abajo. Frenar quita 120 km/h por segundo; soltar todo quita 25.

9. **La dirección no actúa parado y es más lenta a gran velocidad.**
   - 9.1 Cómo: automático, según la velocidad del coche.

10. **En LOCAL, el teclado juega solo si es la única persona; con 2 o más personas, solo mandos.**
    - 10.1 Cómo: en la pantalla de unión, Enter sienta al teclado si nadie más se ha unido; un mando que se une después le quita
      el asiento. Cada mando conduce con la asignación de botones de arriba.

---

## Sección 3. Obstáculos y tráfico

11. **El tráfico son coches amarillos, salmón y azules, y camiones.**
    - 11.1 Cómo: aparecen nuevos coches arriba: amarillos pequeños (60 %, 80–120 km/h, siguen en su carril), salmón (20 %,
      90–110 km/h, un cambio de carril), azules (10 %, 100–130 km/h, dos o tres cambios y se acercan a tu carril) y camiones
      (10 %, 60 km/h). Los cambios de carril son solo a un carril vecino.

12. **Chocar con un coche provoca un derrape y no cuesta combustible.**
    - 12.1 Cómo: tocar un coche amarillo, salmón o azul inicia un derrape que te aleja de él. Cada coche te golpea una vez como máximo.

13. **Un camión te elimina al instante.**
    - 13.1 Cómo: tocar un camión termina la partida (juego por etapas) o te elimina de la ronda (LOCAL).

14. **Las manchas de aceite hacen derrapar el coche.**
    - 14.1 Cómo: al pasar por una mancha el coche derrapa a izquierda o derecha. Girar hacia el lado del derrape lo detiene en
      0,25 s; girar al otro lado o no girar lo deja seguir.

15. **Tocar la barrera lateral es un choque.**
    - 15.1 Cómo: al tocar la barrera de cualquier lado, la velocidad se multiplica por 0,3 y se pierden 5 o 6 de combustible.

16. **Tras un golpe o un choque el coche parpadea unos 1,5 s y es invulnerable.**
    - 16.1 Cómo: mientras parpadea no le afectan coches, camiones ni barrera; el aceite y los autos de combustible sí.

17. **El tráfico se vuelve más denso con el tiempo.**
    - 17.1 Cómo: en el juego por etapas, cada etapa separa los coches y las manchas 0,9 veces lo que la anterior. En LOCAL, lo mismo cada
      20 s (1200 pasos), con un mínimo de 40 px entre coches; los autos arcoíris no cambian.

---

## Sección 4. Combustible y puntos

18. **El combustible baja con el tiempo.**
    - 18.1 Cómo: el tanque tiene 100 y pierde 1 por segundo, se mueva o no. Con el tanque vacío se termina la partida (juego por etapas)
      o se queda eliminado (LOCAL).

19. **Los autos arcoíris dan combustible y puntos.**
    - 19.1 Cómo: tocar uno da +10 de combustible (hasta 100) y +1000 puntos. En LOCAL lo recibe el primer coche que lo toca (el de
      centro más cercano; si empatan, el asiento más bajo).

20. **Se ganan puntos por adelantar.**
    - 20.1 Cómo: +50 por cada coche o camión adelantado (una vez por jugador). En el juego por etapas, +30 por cada unidad entera de
      combustible que sobre al completar una etapa.

21. **En LOCAL también se ganan puntos por distancia.**
    - 21.1 Cómo: +10 por cada 100 px de mundo recorridos.

---

## Sección 5. Reglas de LOCAL

22. **La cámara sigue al líder.**
    - 22.1 Cómo: automático: la cámara va al coche vivo más adelantado, sea jugador o bot, y nunca retrocede.

23. **El borde inferior de la pantalla empuja a quien se queda atrás y le quita combustible.**
    - 23.1 Cómo: mientras un coche toca el borde inferior es empujado hacia delante, pierde 2 de combustible por segundo además del
      gasto normal, y no gana puntos por adelantar ni por distancia. Su panel muestra EDGE.

24. **Los jugadores se atraviesan entre sí.**
    - 24.1 Cómo: los coches de los jugadores no chocan entre ellos; solo chocan con el tráfico.

25. **Una ronda termina cuando un jugador humano es eliminado.**
    - 25.1 Cómo: se elimina por camión o por tanque vacío. Un bot eliminado desaparece y la ronda sigue.
    - 25.2 Gana la ronda el humano vivo con más puntos (luego más distancia, luego más combustible). Si hay un solo humano, gana
      solo si supera a cada bot vivo. Si todos los bots quedan eliminados con un solo humano, la ronda termina y gana el humano.

26. **Cada ronda empieza de cero.**
    - 26.1 Cómo: se reinician puntos, distancia, combustible, tráfico y dificultad. Los resultados se muestran en un panel; tras 1 s
      se continúa con A o Start.

27. **Al terminar la partida se puede hacer revancha.**
    - 27.1 Cómo: A o Start dan la revancha con los mismos asientos y tráfico nuevo; B o Back vuelve a la pantalla de unión con los
      mismos jugadores.

---

## Sección 6. Unirse, mandos y asientos

28. **Cada jugador se une con su mando (o el teclado, si juega solo) y recibe su color.**
    - 28.1 Cómo: en la pantalla de unión, pulsar A en un mando (o Enter en el teclado) toma el asiento libre más bajo. Cualquier
      jugador unido empieza con Start (Enter en el teclado). B (Backspace en el teclado) abandona el asiento; Back o Esc vuelve al título.
    - 28.2 Colores: P1 rubí, P2 turquesa, P3 lila, P4 ciruela, P5 marrón, P6 rosa. Es la única forma de distinguir a los jugadores.
      Ningún color de jugador coincide con los del tráfico (salvo el auto arcoíris, que es la excepción declarada).

29. **Si un mando se desconecta, un bot toma su auto sin parar la ronda.**
    - 29.1 Cómo: automático; el panel muestra NO PAD. Al reconectarse, el mismo mando recupera su asiento; si no, cualquier mando sin
      asiento puede tomarlo pulsando A.

30. **Cualquier jugador puede pausar.**
    - 30.1 Cómo: Start en cualquier mando pausa y reanuda. En pausa, Back sale al título. Perder el foco de la ventana también pausa.

31. **El jugador de teclado pausa con Esc o P; salir de una pausa al título es con Backspace (teclado) o Back (mando).**

---

## Sección 7. Pantalla e interfaz

32. **Formato 16:9 con una carretera de 6 carriles.**
    - 32.1 Cómo: el juego se dibuja en 640×360 y se escala en múltiplos enteros (×3 = 1920×1080) con filtro Nearest, para que el
      pixel art se vea nítido.

33. **Pantalla completa.**
    - 33.1 Cómo: F11 o Alt+Enter, en cualquier pantalla. Si el monitor es pequeño, la ventana se ajusta al mayor múltiplo entero que quepa.

34. **HUD del juego por etapas y panel por auto en LOCAL.**
    - 34.1 Juego por etapas (ya fuera del menú): puntos, récord, etapa, velocidad, marcha, combustible y avance hacia la meta, con aviso LOW FUEL.
    - 34.2 LOCAL: un panel por auto junto a la carretera (P1–P3 a la izquierda, P4–P6 a la derecha), con su color, nombre (P# o BOT),
      puntos, combustible, rondas ganadas y las marcas OUT, EDGE, LOW FUEL o NO PAD.

35. **Arte con recursos libres.**
    - 35.1 Sprites de GrafxKid (CC0) y fuente Press Start 2P (OFL-1.1); el camión y la mancha de aceite están dibujados en código.
      Sin sonido: el juego no tiene audio. Créditos y licencias en `ASSETS.md`.

---

## Sección 8. Características técnicas

36. **Motor: Godot 4.7.2, lenguaje GDScript, renderizador de compatibilidad (gl_compatibility).**

37. **Modo LOCAL de hasta 6 coches en una sola pantalla.** El modo ONLINE todavía no existe (no hay red ni servidor).

38. **Soporte de mandos sin límite fijo de 4.** Se lee cada mando por separado (con tolerancia de 0,5 en las palancas) y se identifica
    por su GUID para devolverle su asiento al reconectar.

39. **Steam Input con GodotSteam 4.23.1** (cuando el juego se ejecuta desde Steam).
    - 39.1 Cómo: cada mando que Steam ve (hasta 16, de cualquier marca, también los de Remote Play Together) se lee mediante el
      manifiesto de acciones de `steam_input/` y juega como un mando más. Permite pasar del límite de 4 mandos Xbox de Windows.
    - 39.2 Sin cliente de Steam, o en una build sin GodotSteam, el juego avisa una vez ("Steam Input is off") y lee los mandos por sí mismo.
      `--no-steam` desactiva Steam Input. En desarrollo se usa el App ID 480 (Spacewar).

40. **Simulación pura y determinista.**
    - 40.1 Cómo: las reglas están en `scripts/sim/` sin nodos de Godot; avanzan en pasos fijos de 1/60 s con un byte de entrada por
      asiento. La misma semilla y las mismas entradas dan la misma partida, bit a bit. Lo usan las pruebas y es la base prevista para el online.
    - 40.2 El generador de números aleatorios es propio (mulberry32). El estado completo se puede guardar, restaurar y resumir con un SHA-256.

41. **Fidelidad con el prototipo original.** Las reglas del juego por etapas reproducen exactamente una traza de 10 800 pasos grabada del prototipo
    en Phaser (el original está en el commit `0a0841f`).

42. **Plataformas de exportación: Linux y Windows (escritorio), con y sin Steam.**
    - 42.1 Cómo: `tools/export_builds.sh` genera cuatro builds (Linux, Windows Desktop, Linux Steam, Windows Steam) con el paquete
      embebido. Las de Steam incluyen las librerías de GodotSteam y el manifiesto de Steam Input.

43. **Pruebas automáticas.**
    - 43.1 339 tests con un runner propio (`tools/test.sh`), prueba de humo del juego por etapas y de LOCAL (`tools/run_tool.sh smoke`),
      comprobación de la escala entera (`scalecheck`), capturas de pantalla comprobadas por píxeles, QA de LOCAL con 6 asientos
      (`tools/run_tool.sh versus_qa`) y comprobación de exportación (`tools/export_check.sh`).
    - 43.2 Modo `--selftest` dentro de cualquier build exportada, y opción `--seed=N` para fijar la semilla.

44. **Integración continua en GitHub Actions** (`.github/workflows/ci.yml`): descarga y verifica Godot 4.7.2, ejecuta los tests, la
    prueba de humo, la exportación del paquete, el QA de LOCAL con un jugador y las cuatro builds.

45. **Resolución del daltonismo en los colores de jugador.** Se midieron las distancias de color (CIEDE2000) con simulación de
    protanopia, deuteranopia y tritanopia; algunos pares siguen cercanos y por eso las etiquetas P1–P6 y BOT permanecen en pantalla.

---

## Sección 9. Lo que el juego NO tiene

- No hay inicio de sesión (ni con Google ni con otra cuenta), ni cuentas de usuario.
- No hay juego online ni servidor; el multijugador es solo local (LOCAL).
- No hay sonido ni música.
- No se guarda nada: la mejor puntuación dura solo mientras la sesión está abierta.
- No hay controles táctiles, versión web ni potenciadores (las 30 ideas de power-ups están pendientes).
- ONLINE aparece en el menú pero está bloqueado ("COMING SOON").
- El teclado solo juega en LOCAL cuando es la única persona.

## Sección 10. Sin verificar todavía

- Las builds de Windows se generan pero no se han ejecutado.
- Steam Input real, Remote Play Together con 6 jugadores y 6 mandos físicos no se han probado (no hay cliente de Steam ni mandos aquí).
- Nadie ha jugado aún contra los bots: el equilibrio, sobre todo un humano contra 5 bots, es un punto por ajustar. En simulación, un
  "humano" que juega igual que los bots ganó solo 1 de 20 partidas.
- El nombre "Fuel Rivals" no se ha comprobado como marca y falta el App ID real de Steam.

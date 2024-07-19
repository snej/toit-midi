// Copyright 2024 Jens Alfke. All rights reserved.
// Use of this source code is governed by the Apache 2 license.

/*
    A simple delay/echo effect: repeats every note once.

    - The delay defaults to 1 second, and can be controlled with CC 82 in a range of 0.1 … 2 secs.
      If there's an LED on GPIO 5 it will blink in time.
    - Echoed notes can be pitch-shifted. The default is up 7 semitones (a fifth); this can be
      controlled with CC 83 in a range of ±12 semitones (up/down an octave.)
*/

import midi
import gpio
import log

LED-PIN ::= 5                       // GPIO pin of the ESP32 Thing's built-in LED

DELAY-CC ::= 82                     // MIDI CC controlling the delay
MIN-DELAY ::= Duration --ms=100     // Minimum delay (at 0)
MAX-DELAY ::= Duration --ms=2000    // Maximum delay (at 127)

INTERVAL-CC ::= 83                  // MIDI CC controlling the transposition interval
MIN-INTERVAL ::= -12                // Minimum interval
MAX-INTERVAL ::=  12                // Maximum interval

delay /Duration := Duration --s=1   // Initial delay
interval /int := 7                  // Initial interval

main:
    log.set_default (log.default.with_level log.INFO_LEVEL)
    port := midi.SerialPort.uart --tx=(gpio.Pin 17) --rx=(gpio.Pin 16)
    task ::blink-metronome

    print "Hello, MIDI! Echoing notes after $delay ..."

    while true:
        msg := port.receive
        if msg.type == midi.NOTE-ON or msg.type == midi.NOTE-OFF:
            port.send msg
            echo := msg.copy
            echo.time = msg.time + delay
            echo.item = min 127 (max 0 (echo.item + interval))
            echo.value = echo.value / 2
            port.send echo
        else if msg.type == midi.CC:
            if msg.item == DELAY-CC:
                delay = interpolate msg.value MIN-DELAY MAX-DELAY
                print "Echoing notes after $delay"
            else if msg.item == INTERVAL-CC:
                i := (interpolate msg.value MIN-INTERVAL MAX-INTERVAL).to-int
                if i != interval:
                    interval = i
                    print "Interval is $interval"

interpolate val/int min max:
    f := val / 127.0
    return (max * f) + (min * (1.0 - f))

pin := gpio.Pin LED-PIN --output

blink-metronome:
    while true:
        pin.set 1
        sleep delay * .25
        pin.set 0
        sleep delay * .75

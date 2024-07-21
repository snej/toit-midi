// Copyright 2024 Jens Alfke. All rights reserved.
// Use of this source code is governed by the Apache 2 license.

/*
    A trivial MIDI program: just routes messages from the input to the output,
    and logs them to the console.
*/

import midi
import gpio
import log

main:
    print "Hello, MIDI! Forwarding messages..."
    port := midi.SerialPort.uart --tx=(gpio.Pin 17) --rx=(gpio.Pin 16)
    prev-type/int := -1
    while true:
        msg := port.receive
        port.send msg
        // Log the message, but suppress multiple pressure messages since they tend to be sent
        // at very high rates:
        if (msg.type != midi.POLY-AFTERTOUCH and msg.type != midi.CHANNEL-PRESSURE) \
            or (msg.type != prev-type):
                print "--> $msg"
        prev-type = msg.type

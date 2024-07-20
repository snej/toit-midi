// Copyright 2024 Jens Alfke. All rights reserved.
// Use of this source code is governed by the Apache 2 license.

import .message
import .timed-queue
import gpio
import io.reader
import io.writer
import log
import monitor
import uart

LOG ::= (log.default.with-level log.INFO-LEVEL).with-name "MIDI"
TAGS_ ::= {"time": TIMESTAMP_}

/** Represents a MIDI in/out connection, using any Reader/Writer stream pair. */
class Port:
    /** Constructs a Port given a Reader and Writer. */
    constructor .in_/reader.Reader .out_/writer.Writer:
        task --background=true ::send-task_

    /** Waits for the next message and returns it. */
    receive -> Message:
        msg := null
        while msg == null:
            msg = Message.read in_
            if sysex-in_ == false:
                if msg.type == SYSEX-BEGIN:
                     sysex-in_ = true
                else if not msg.allowed-outside-sysex_:
                    // Ignore Sysex data or ending without a matching begin
                    msg = null
            else:
                if msg.type == SYSEX-END:
                    sysex-in_ = false
                else if not msg.allowed-in-sysex_:
                    // Ignore a non-real-time message during a Sysex dump
                    msg = null
        LOG.info " ---> $msg" --tags=TAGS_
        return msg

    /** Queues a message to be sent.

        If you set the message's `time` property to a future time, the message will be held
            and sent at that time. (Multiple future messages are sent in the order of their
            timestamps, not the order they were queued.) */
    send msg/Message -> none:
        outbox_.send msg

    send-task_:
        while true:
            msg := outbox_.receive
            send-now_ msg

    send-now_ msg/Message -> none:
        if sysex-out_:
            if not msg.allowed-in-sysex_:
                LOG.warn "MIDI message not allowed during a SYSEX dump: $msg"
                return
            if msg.type == SYSEX-END: sysex-out_ = false
        else:
            if not msg.allowed-outside-sysex_:
                LOG.warn "MIDI message not allowed outside of a SYSEX dump: $msg"
                return
            if msg.type == SYSEX-BEGIN: sysex-out_ = true
        msg.write-to out_
        LOG.info "<=== $msg" --tags=TAGS_

    in_ /reader.Reader ::= ?            // Input stream
    out_ /writer.Writer ::= ?           // Output stream
    outbox_ /TimedQueue ::= TimedQueue  // Messages queued to be sent
    sysex-in_ /bool := false            // input stream is sending SYSEX data
    sysex-out_ /bool := false           // output stream is sending SYSEX data



/** Represents a serial MIDI connection. */
class SerialPort extends Port:
    /** Constructor using GPIO pins. Preferred pins on ESP-32 are tx = 17, rx = 16. */
    constructor.uart --tx /gpio.Pin --rx /gpio.Pin:
        port_ = uart.Port --rx=rx --tx=tx \
            --baud-rate=31250 --data-bits=8 --stop-bits=uart.Port.STOP-BITS-1 \
            --parity=uart.Port.PARITY-DISABLED
        super port_.in port_.out

    /** Constructor using serial device on a 'real OS'. */
    constructor.dev device/string:
        port_ = uart.Port device --baud-rate=31250 --data-bits=8 --stop-bits=uart.Port.STOP-BITS-2
        super port_.in port_.out

    port_ /uart.Port ::= ?

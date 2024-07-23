// Copyright 2024 Jens Alfke. All rights reserved.
// Use of this source code is governed by the Apache 2 license.

import .logging as log
import .message
import .timed-queue
import gpio
import io.buffer
import io.reader
import io.writer
import monitor
import uart

/** Represents a MIDI in/out connection, using any Reader/Writer stream pair. */
class Port:
    /** Constructs a Port given a Reader and Writer. */
    constructor .in_/reader.Reader .out_/writer.Writer:
        inbox_ = monitor.Channel 10
        outbox_ = TimedQueue
        receive-task_ = task --name="MIDI Receive" --background=true ::receive-loop_
        send-task_    = task --name="MIDI Send"    --background=true ::send-loop_


    /** If set to true, all incoming and outgoing messages will be logged.
        This should only be used for debugging, as it slows everything down a lot. */
    log-messages /bool := false


    /** Waits for the next message and returns it. */
    receive -> Message:
        return inbox_.receive


    /** Queues a message to be sent.

        If you set the message's `time` property to a future time, the message will be held
            and sent at that time. (Multiple future messages are sent in the order of their
            timestamps, not the order they were queued.) */
    send msg/Message -> none:
        outbox_.send msg


    /** Closes the MIDI port. */
    close:
        send-task_.cancel
        receive-task_.cancel


    // The Task that reads Messages from the input.
    receive-loop_:
        last-status/int := 0
        while not Task.current.is-canceled:
            // Read the status byte, or else reuse the last one:
            status := read-non-realtime-byte_
            time ::= Time.now
            if status < 0x80:
                if last-status < 0x80: continue
                status = last-status                // reuse last status, if not given
            else if status < 0xF0:
                last-status = status

            // Consult the info table:
            info/int := ?
            if status < 0xF0:
                info = CHANNEL-STATUS-INFO_[(status >>> 4) - 8]
            else:
                info = SYSTEM-STATUS-INFO_[status - 0xF0]
            if info == 0xFF:
                log.warn "Ignoring undefined status byte $(%02x status)"
                continue

            // Read parameter byte(s):
            p1/int? := null
            p2/int? := null
            if (info & BYTES_MASK_) > 0:
                // Read parameter byte(s):
                p1 = read-non-realtime-byte_
                if p1 >= 0x80:
                    log.warn "Ignoring invalid data byte after $(%02x status)"
                    continue
                if (info & BYTES_MASK_) > 1:
                    p2 = read-non-realtime-byte_
                    if p2 >= 0x80:
                        log.warn "Ignoring invalid data byte after $(%02x status)"
                        continue

            // Handle the message:
            if status == SYSEX-BEGIN:
                receive-sysex_ time
            else if status == SYSEX-END:
                continue        // Ignore a mismatched SYSEX-END
            else:
                received_ (Message status --p1=p1 --p2=p2 --time=time)


    // Reads a SYSEX-BEGIN message's vendor ID and the following data until SYSEX-END.
    receive-sysex_ time/Time:
        // Read the vendor ID, either aa or 00 aa bb:
        n := (in_.peek-byte != 0) ? 1 : 3
        vendor := in_.read-bytes n
        received_ (SysexMessage vendor --time=time)

        // Now read data bytes and forward as SYSEX-DATA messages:
        buf := buffer.Buffer
        while true:
            b := in_.peek-byte
            if b < 0x80:
                buf.write-byte (in_.read-byte)
                if buf.size >= 4096:
                    // Break data into 4KB chunks:
                    received_ (SysexDataMessage buf.bytes)
                    buf = buffer.Buffer
            else if b >= 0xF8:
                dispatch-realtime_ b // Handle realtime
            else:
                // Dump ends at the first non-realtime system status byte:
                if buf.size > 0:
                    received_ (SysexDataMessage buf.bytes)
                if b == SYSEX-END:
                    in_.read-byte
                // (If it's not a SYSEX-END, leave the byte unread for the next msg)
                received_ (Message SYSEX-END)
                break


    // Reads a byte from the input. Realtime status bytes are processed immediately;
    // result will not be realtime.
    read-non-realtime-byte_ -> int:
        while true:
            b := in_.read-byte
            if b < 0xF8:
                return b
            dispatch-realtime_ b


    // Handles an input byte F8..FF
    dispatch-realtime_ b/int:
        if SYSTEM-STATUS-INFO_[b - 0xF0] != 0xFF:
            // send real-time message immediately, then loop to wait for the next byte:
            received_ (Message b --time=Time.now)
        else:
            log.warn "Ignoring undefined status byte $(%02x b)"

    received_ msg/Message:
        if log-messages: log.info "---> $msg"
        inbox_.send msg


    send-loop_:
        in-sysex/bool := false
        while not Task.current.is-canceled:
            msg := outbox_.receive
            type := msg.type
            if in-sysex:
                if type < SYSEX-END:
                    log.warn "MIDI message not allowed during a SYSEX dump: $msg"
                    continue
                if type == SYSEX-END: in-sysex = false
            else:
                if type == SYSEX-DATA or type == SYSEX-END:
                    log.warn "MIDI message not allowed outside of a SYSEX dump: $msg"
                    continue
                if type == SYSEX-BEGIN: in-sysex = true
            msg.write-to out_
            if log-messages: log.info "<=== $msg"


    in_ /reader.Reader                  // Input stream
    out_ /writer.Writer                 // Output stream
    inbox_ /monitor.Channel             // Queued incoming messages
    outbox_ /TimedQueue                 // Messages queued to be sent
    send-task_ /Task? := null           // Task that sends Messages
    receive-task_ /Task? := null        // Task that receives Messages

    // Describes status bytes 8x, 9x, Ax, ... Ex
    static CHANNEL-STATUS-INFO_ ::= #[
        0x02, 0x02, 0x02, 0x02, 0x01, 0x01, 0x02 ]
    // Describes status bytes F0, F1, F2 ... FF
    static SYSTEM-STATUS-INFO_ ::= #[
        0x00, 0x01, 0x02, 0x01, 0xFF, 0xFF, 0x00, 0x00,
        0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00 ]
    static BYTES_MASK_ ::= 0x03         // Info mask: Number of bytes following



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

    close:
        super
        port_.close

    port_ /uart.Port ::= ?

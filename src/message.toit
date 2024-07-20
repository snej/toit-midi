// Copyright 2024 Jens Alfke. All rights reserved.
// Use of this source code is governed by the Apache 2 license.

import .note
import io
import io.reader
import io.writer
import log

//-------- MESSAGE TYPES

// CONSTANT                     ITEM        VALUE

// Per-channel messages:
NOTE-OFF         ::= 0x80   //  note#       velocity (usually 0)
NOTE-ON          ::= 0x90   //  note#       velocity
POLY-AFTERTOUCH  ::= 0xA0   //  note#       pressure
CC               ::= 0xB0   //  controller  value
PROGRAM-CHANGE   ::= 0xC0   //  program
CHANNEL-PRESSURE ::= 0xD0   //              pressure (0..16383)
PITCH-BEND       ::= 0xE0   //              bend (-8192..8191)

// System messages: (no channel)
SYSEX-BEGIN      ::= 0xF0   //  vendor-ID
QUARTER-FRAME    ::= 0xF1   //  type        value
SONG-POSITION    ::= 0xF2   //              position (0..16383)
SONG-SELECT      ::= 0xF3   //  song
TUNE-REQUEST     ::= 0xF6   //
SYSEX-END        ::= 0xF7   //

// Real-time messages: (no channel; may occur during a sysex dump)
TIMING-CLOCK     ::= 0xF8   //
START            ::= 0xFA   //
CONTINUE         ::= 0xFB   //
STOP             ::= 0xFC   //
ACTIVE-SENSING   ::= 0xFE   //
RESET            ::= 0xFF   //

// Fake message type to represent data bytes sent between SYSEX-BEGIN and SYSEX-END
SYSEX-DATA       ::= 0x1000


/** A MIDI message; basically a Plain Old Data Object.
    Every message has a $type. The most common messages have a $channel, from 1 to 16.
    Most messages have an $item they target (like a note or controller) and/or a $value. */
class Message implements Comparable:

    /** Message type (see constants e.g. $NOTE-ON, $NOTE-OFF...) */
    type /int ::= ?

    /**  Channel number, 1-16 (for channel-specific messages.) */
    channel /int? := null

    /** The item targeted by this message, if any.
        Meaning depends on the message type: a note, controller, program, vendor ID... */
    item /int? := null

    /** The value contained in this message, if any.
        Meaning depends on the message type:  velocity, pressure, controller value, pitch-bend...
        Generally 0..127, but pitch-bend is -8192..8191 and song position is 0..16383. */
    value /int? := null

    /** Binary data of a $SYSEX-DATA message; part of a Sysex dump. Otherwise null. */
    data /ByteArray? ::= null

    /** The time the message was received, or at which it should be sent. */
    time /Time := ?


    /** The Note of a $NOTE-ON, $NOTE-OFF or $POLY-AFTERTOUCH message. */
    note -> Note:           return Note item


    /** Constructs a new Message. */
    constructor .type/int --.item/int?=null --.value/int?=null:
        if NAMES_[type] == null: throw "Invalid MIDI Message type"
        time = Time.now
        //TODO: Validate item and value!


    /** Constructs a new $SYSEX-DATA message. */
    constructor --.data/ByteArray:
        type = SYSEX-DATA
        time = Time.now


    /** Constructs an exact copy of another Message. */
    constructor.copy msg/Message:
        type = msg.type
        channel = msg.channel
        item = msg.item
        value = msg.value
        data = msg.data
        time = msg.time


    /** Constructs a Message from bytes read from a MIDI stream. */
    constructor.read in /reader.Reader:
        b := in.peek-byte   // Wait for next byte...
        time = Time.now
        if b >= 0x80:
            // Read a MIDI message:
            b = in.read-byte
            type = b & 0xF0
            if type != 0xF0:
                // Channel messages:
                channel = 1 + (b & 0x0F)
                item = in.read-byte
                if type == PROGRAM-CHANGE or type == CHANNEL-PRESSURE:
                    value = item
                    item = null
                else:
                    value = in.read-byte
                    if type == PITCH-BEND:
                        // Combine 2 param bytes into one 14-bit number:
                        value = ((value << 7) | item) - 8192
                        item = null
            else:
                // System messages:
                type = b // use entire byte as type
                if type == SYSEX-BEGIN:
                    // Read manufacturer id, either 1 or 3 bytes:
                    item = in.read-byte
                    if item == 0:
                        item = (in.read-byte << 8) | in.read-byte
                else if type == QUARTER-FRAME:
                    q := in.read-byte
                    item = q >>> 4
                    value = q & 0x0F
                else if type == SONG-POSITION:
                    lsb := in.read-byte
                    msb := in.read-byte
                    value = (msb << 7) | lsb
                else if type == SONG-SELECT:
                    item = in.read-byte

        else:
            // Byte is < 0x80 so this is data. Grab all available data bytes:
            type = SYSEX-DATA
            sz ::= in.buffered-size
            len := 1
            for ; len < sz; len++:
                if (in.peek-byte len) >= 0x80:
                    break
            data = in.read-bytes len


    /** Writes a Message to a MIDI stream. */
    write-to out /writer.Writer:
        if type == SYSEX-DATA:
            // Data:
            out.write data
        else if type < 0xF0:
            // Channel message:
            out.write-byte (type | (channel - 1))
            if type == PITCH-BEND:
                v := value + 8192
                out.write-byte (v & 0x7F)
                out.write-byte (v >>> 7)
            else:
                if item != null:   out.write-byte item
                if value != null:  out.write-byte value
        else:
            // System messages:
            out.write-byte type
            if type == SYSEX-BEGIN:
                // Write manufacturer id, either 1 or 3 bytes:
                if item <= 0xFF:
                    out.write-byte item
                else:
                    out.write-byte 0x00
                    out.write-byte (item >>> 8)
                    out.write-byte (item & 0xFF)
            else if type == QUARTER-FRAME:
                out.write-byte (item << 4) | value
            else if type == SONG-POSITION:
                out.write-byte (value & 0x7F)
                out.write-byte (value >>> 7)
            else if type == SONG-SELECT:
                out.write-byte item


    /** Returns a copy of this Message. */
    copy -> Message:
        return Message.copy this


    /** Human-readable description of the message. */
    stringify:
        str := NAMES_[type]
        if type == NOTE-ON or type == NOTE-OFF or type == POLY-AFTERTOUCH:
            str += " $note"
        else if item != null:
            str += " $item"
        if value != null:
            str += " = $value"
        if type < SYSEX-BEGIN:
            str += " (ch$channel)"
        if data != null:
            str += " <$data.size bytes>"
        //str += " @$(%.3f (time.ms-since-epoch / 1000.0))"
        return str


    /** Messages are compared by their timestamps. */
    compare-to other/Message -> any:
        return time.compare-to other.time
    compare-to other/Message [--if-equal] -> any:
        return time.compare-to other.time --if-equal=if-equal


    allowed-in-sysex_     -> bool:  return type >= SYSEX-END
    allowed-outside-sysex_-> bool:  return type != SYSEX-DATA and type != SYSEX-END


    /** A mapping from message types to names. */
    static NAMES_ ::= {
        NOTE-OFF:       "NOTE-OFF",
        NOTE-ON:        "NOTE-ON",
        POLY-AFTERTOUCH:"POLY-AFTERTOUCH",
        CC:             "CC",
        PROGRAM-CHANGE: "PROGRAM-CHANGE",
        CHANNEL-PRESSURE:"CHANNEL-PRESSURE",
        PITCH-BEND:     "PITCH-BEND",
        SYSEX-BEGIN:    "SYSEX-BEGIN",
        QUARTER-FRAME:  "QUARTER-FRAME",
        SONG-POSITION:  "SONG-POSITION",
        SONG-SELECT:    "SONG-SELECT",
        TUNE-REQUEST:   "TUNE-REQUEST",
        SYSEX-END:      "SYSEX-END",
        TIMING-CLOCK:   "TIMING-CLOCK",
        START:          "START",
        CONTINUE:       "CONTINUE",
        STOP:           "STOP",
        ACTIVE-SENSING: "ACTIVE-SENSING",
        RESET:          "RESET",
        SYSEX-DATA:     "SYSEX-DATA"
    }

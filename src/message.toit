// Copyright 2024 Jens Alfke. All rights reserved.
// Use of this source code is governed by the Apache 2 license.

import .note
import io
import io.reader
import io.writer

//-------- MESSAGE TYPES

// CONSTANT                         ITEM        VALUE

// Per-channel messages:
NOTE-OFF            ::= 0x80    //  note#       velocity (usually 0)
NOTE-ON             ::= 0x90    //  note#       velocity
POLY-AFTERTOUCH     ::= 0xA0    //  note#       pressure
CC                  ::= 0xB0    //  controller  value
PROGRAM-CHANGE      ::= 0xC0    //  program
CHANNEL-PRESSURE    ::= 0xD0    //              pressure (0..16383)
PITCH-BEND          ::= 0xE0    //              bend (-8192..8191)

RPN                 ::= 0x100   // controller   value  (both 0..16383)
NRPN                ::= 0x110   // controller   value  (both 0..16383)

// Channel mode messages (implemented as CC controllers 120..127)
CHANNEL-MODE-BASE_  ::= 0x1C1
SOUND-OFF           ::= 0x1C1
RESET-CONTROLLERS   ::= 0x1C2
LOCAL-CONTROL       ::= 0x1C3  //              0 off, 127 on
NOTES-OFF           ::= 0x1C4
OMNI-OFF            ::= 0x1C5
OMNI-ON             ::= 0x1C6
MONO-MODE           ::= 0x1C7  //              number of channels, 0 for all
POLY-MODE           ::= 0x1C8
CHANNEL-MODE-END_   ::= POLY-MODE

// System messages: (no channel)
SYSTEM-BASE_        ::= 0xF0
SYSEX-BEGIN         ::= 0xF0    //  `vendor` property has the vendor ID
QUARTER-FRAME       ::= 0xF1    //  type        value
SONG-POSITION       ::= 0xF2    //              position (0..16383)
SONG-SELECT         ::= 0xF3    //  song
TUNE-REQUEST        ::= 0xF6
SYSEX-END           ::= 0xF7

SYSEX-DATA          ::= 0x1F4   //  `data` property contains the data

// Real-time messages: (no channel; allowed during a sysex dump)
REALTIME-BASE_      ::= 0xF8
TIMING-CLOCK        ::= 0xF8
START               ::= 0xFA
CONTINUE            ::= 0xFB
STOP                ::= 0xFC
ACTIVE-SENSING      ::= 0xFE
RESET               ::= 0xFF



/** A MIDI message; basically a Plain Old Data Object.
    Every message has a $type. The most common messages have a $channel, from 1 to 16.
    Most messages have an $item they target (like a note or controller) and/or a $value. */
class Message implements Comparable:

    /** Message type (see constants e.g. $NOTE-ON, $NOTE-OFF...) */
    type /int

    /**  Channel number, 1-16 (for channel-specific messages.) */
    channel /int? := null

    /** The item targeted by this message, if any.
        Meaning depends on the message type: a note, controller, program, vendor ID... */
    item /int? := null

    /** The value contained in this message, if any.
        Meaning depends on the message type:  velocity, pressure, controller value, pitch-bend...
        Generally 0..127, but pitch-bend is -8192..8191 and song position is 0..16383. */
    value /int? := null

    /** The time the message was received, or at which it should be sent.
        Defaults to the time the Message object was constructed. */
    time /Time := ?

    is-channel-message -> bool:         return (type & 0xFF) < SYSTEM-BASE_
    is-system-message -> bool:          return not is-channel-message

    /** The Note of a $NOTE-ON, $NOTE-OFF or $POLY-AFTERTOUCH message. */
    note -> Note:           return Note item


    /** Constructs a new Message. */
    constructor .type/int --.item/int?=null --.value/int?=null:
        if NAMES_[type] == null:
            throw "Invalid MIDI Message type"
        if type == SYSEX-BEGIN or type == SYSEX-DATA:
            throw "Sysex messages must have Message subclasses"
        time = Time.now
        //TODO: Validate item and value!


    constructor.copy msg/Message:
        type = msg.type
        channel = msg.channel
        item = msg.item
        value = msg.value
        time = msg.time


    /** Constructs a Message from bytes read from a MIDI stream. */
    constructor status/int --p1/int?=null --p2/int?=null --.time/Time:
        if status < 0xF0:
            // Channel messages:
            type = status & 0xF0
            channel = 1 + (status & 0x0F)
            if type == PROGRAM-CHANGE or type == CHANNEL-PRESSURE:
                value = p1
            else if type == CC and p1 >= 120:
                // Channel Mode Messages:
                type = CHANNEL-MODE-BASE_ + (p1 - 120)
                value = p2
            else if type == PITCH-BEND:
                // Combine 2 param bytes into one 14-bit number:
                value = ((p2 << 7) | p1) - 8192
            else:
                item = p1
                value = p2
                if type == NOTE-ON and p2 == 0:
                    type = NOTE-OFF
        else:
            // System messages:
            type = status // use entire byte as type
            if type == QUARTER-FRAME:
                item = p1 >>> 4
                value = p1 & 0x0F
            else if type == SONG-POSITION:
                value = (p2 << 7) | p1
            else if type == SONG-SELECT:
                item = p1


    /** Writes a Message to a MIDI stream. */
    write-to out /writer.Writer:
        if type >= CHANNEL-MODE-BASE_ and type <= CHANNEL-MODE-END_:
            // Channel mode messages (really CCs):
            out.write-byte (CC | (channel - 1))
            out.write-byte (type - CHANNEL-MODE-BASE_ + 120)
            write-data-byte_ out value
        else if is-channel-message:
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
            if type == QUARTER-FRAME:
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
        //str += " @$(%.3f (time.ms-since-epoch / 1000.0))"
        return str


    /** Messages are compared by their timestamps. */
    compare-to other/Message -> any:
        return time.compare-to other.time
    compare-to other/Message [--if-equal] -> any:
        return time.compare-to other.time --if-equal=if-equal



/** Message subclass for $SYSEX-BEGIN messages, which have a vendor identifier. */
class SysexMessage extends Message:
    /** MIDI Vendor ID: either one nonzero byte, or three bytes the first of which is zero. */
    vendor /ByteArray

    constructor .vendor/ByteArray --time=Time.now:
        super SYSEX-BEGIN --time=time
        if not ((vendor.size == 1 and vendor[0] == 0) or (vendor.size == 3 and vendor[0] == 0)):
            throw "Invalid MIDI vendor ID"

    copy -> SysexMessage:
        return SysexMessage vendor --time=time

    write-to out/writer.Writer:
        out.write-byte SYSEX-BEGIN
        out.write vendor

    stringify -> string:
        return super.stringify + " $vendor"



/** Message subclass for Sysex data, which occurs after a $SYSEX-BEGIN and before a $SYSEX-END. */
class SysexDataMessage extends Message:
    /** Binary data, part of a Sysex dump. All bytes must be <= 0x7F. */
    data /ByteArray

    constructor .data/ByteArray --time=Time.now:
        super SYSEX-DATA --time=time

    copy -> SysexDataMessage:
        return SysexDataMessage data --time=time

    write-to out/writer.Writer:
        out.write data

    stringify -> string:
        return super.stringify + " $data.size bytes"


write-data-byte_ out/writer.Writer status/int:
    if status < 0 or status >= 0x80: throw "invalid MIDI parameter (out of range 0..127)"
    out.write-byte status


/** A mapping from message types to names. */
NAMES_ ::= {
    NOTE-OFF:           "NOTE-OFF",
    NOTE-ON:            "NOTE-ON",
    POLY-AFTERTOUCH:    "POLY-AFTERTOUCH",
    CC:                 "CC",
    PROGRAM-CHANGE:     "PROGRAM-CHANGE",
    CHANNEL-PRESSURE:   "CHANNEL-PRESSURE",
    PITCH-BEND:         "PITCH-BEND",

    SOUND-OFF:          "SOUND-OFF",
    RESET-CONTROLLERS:  "RESET-CONTROLLERS",
    LOCAL-CONTROL:      "LOCAL-CONTROL",
    NOTES-OFF:          "NOTES-OFF",
    OMNI-OFF:           "OMNI-OFF",
    OMNI-ON:            "OMNI-ON",
    MONO-MODE:          "MONO-MODE",
    POLY-MODE:          "POLY-MODE",

    SYSEX-BEGIN:        "SYSEX-BEGIN",
    QUARTER-FRAME:      "QUARTER-FRAME",
    SONG-POSITION:      "SONG-POSITION",
    SONG-SELECT:        "SONG-SELECT",
    TUNE-REQUEST:       "TUNE-REQUEST",
    SYSEX-END:          "SYSEX-END",
    SYSEX-DATA:         "SYSEX-DATA",

    TIMING-CLOCK:       "TIMING-CLOCK",
    START:              "START",
    CONTINUE:           "CONTINUE",
    STOP:               "STOP",
    ACTIVE-SENSING:     "ACTIVE-SENSING",
    RESET:              "RESET",
}

// Copyright 2024 Jens Alfke. All rights reserved.
// Use of this source code is governed by the Apache 2 license.

/** A musical note. Wrapper around a MIDI note number 0-127, where 0 is low C. */
class Note:

    /** Constructs a Note from the MIDI note number (0..127).
        0 is middle C, and there are as usual 12 notes in an octave. */
    constructor .number/int:
        if number < 0 or number > 127: throw "invalid MIDI note number"

    /** Constructs a Note from a note number (0..11) and octave (0..10). */
    constructor --note/int --octave/int:
        if note < 0 or note > 11: throw "note number out of range"
        number = 12 * octave + note
        if number < 0 or number > 127: throw "octave out of range"

    /** The MIDI note number (0..127) */
    number/int ::= ?

    /** The note's octave (0..10). */
    octave -> int:  return number / 12

    /** The note number within the octave (0..11) where 0 is C and 11 is B#. */
    note -> int:    return number % 12

    /** The name of the note, e.g. "C" or "G#". (Only uses sharps, not flats.) */
    name -> string:
        if NAMES_[note] == '#':
            return NAMES_[note - 1 .. note + 1]
        else:
            return NAMES_[note .. note + 1]

    /** The string representation is the name followed by the octave, e.g. "A2" */
    stringify -> string:
        return "$name$octave"

    static C        ::= 0
    static C-SHARP  ::= 1
    static D        ::= 2
    static D-SHARP  ::= 3
    static E        ::= 4
    static F        ::= 5
    static F-SHARP  ::= 6
    static G        ::= 7
    static G-SHARP  ::= 8
    static A        ::= 9
    static A-SHARP  ::= 10
    static B        ::= 11

    static NAMES_ ::= "C#D#EF#G#A#B"

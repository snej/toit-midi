// Copyright 2024 Jens Alfke. All rights reserved.
// Use of this source code is governed by the Apache 2 license.

import .message
import .timestamp
import log
import monitor

/** A queue of $Message objects, ordered chronologically (by their `$time` property.)
    Messages cannot be removed from the queue until their time is reached. */
class TimedQueue:
    events_/Deque ::= Deque                     // The queue, in chronological order
    signal_/monitor.Signal ::= monitor.Signal   // Raises when a message is enqueued

    constructor:
        // noop

    /** Adds a Message to the queue. */
    send event/Message -> none:
        log.debug "$TIMESTAMP Q: Enqueuing $event"
        re-sort := (not events_.is-empty and (event.compare-to events_.last) <= 0)
        events_.add event
        if re-sort:
            events_.sort --in-place=true : |a b| a.time.compare-to b.time
        log.debug "       Q: $events_"
        signal_.raise
        //TODO: This method could be optimized by using a priority queue aka heap.

    /** The time of the next Message, or null if the queue is empty. */
    next-time -> Time?:
        if events_.is-empty: return null
        return events_.first.time

    /** If the first Message in the queue has a time that's now or in the past,
            removes and returns it.
        Otherwise, or if the queue is empty, returns null. */
    try-receive -> Message?:
        if not events_.is-empty and events_.first.time >= Time.now:
            return events_.remove-first
        else:
            return null

    /** Waits until a Message is ready (its time has arrived), then removes and returns it. */
    receive -> Message:
        while true:
            t := next-time
            if t == null:
                // Wait for a notification that a Message has been pushed:
                log.debug "$TIMESTAMP Q: Waiting on empty queue..."
                signal_.wait
            else:
                // Check if the earliest Message is ready now, or how soon it will be ready:
                delay := -(t.to-now)
                if delay <= Duration.ZERO:
                    // It's ready! Remove & return it:
                    log.debug "$TIMESTAMP Q: Got a message! (t=$t.ms-since-epoch) delay=$delay)"
                    return events_.remove-first
                // Wait for a notification that a Message has been pushed,
                // but abort the wait when the current first Message is ready:
                log.debug "$TIMESTAMP Q: Waiting $delay (until $t.ms-since-epoch) before next Message..."
                catch:
                    with-timeout delay:
                        signal_.wait

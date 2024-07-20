import log

LOG ::= (log.default.with-level log.INFO-LEVEL).with-name "MIDI"

class Timestamp_:
  stringify -> string:
      return "$(%7.3f (Time.now.ms-since-epoch / 1000.0))"

TIMESTAMP_ ::= Timestamp_
TAGS_ ::= {"time": TIMESTAMP_}

debug msg/string -> none: LOG.debug "$TIMESTAMP_: $msg"
info  msg/string -> none: LOG.info  "$TIMESTAMP_: $msg"
warn  msg/string -> none: LOG.warn  "$TIMESTAMP_: $msg"
error msg/string -> none: LOG.error "$TIMESTAMP_: $msg"

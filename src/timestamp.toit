// Copyright 2024 Jens Alfke. All rights reserved.
// Use of this source code is governed by the Apache 2 license.


class Timestamp:
    stringify -> string:
        return "$(%7.3f (Time.now.ms-since-epoch / 1000.0))"

TIMESTAMP ::= Timestamp

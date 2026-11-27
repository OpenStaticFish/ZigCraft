"""Git textconv for pinned reviews: preserve text and identify binary blobs."""

import hashlib
import mmap
import os
import sys

with open(sys.argv[1], "rb") as source:
    if os.fstat(source.fileno()).st_size:
        with mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as blob:
            if blob.find(b"\0") >= 0:
                print("Binary blob SHA-256:", hashlib.sha256(blob).hexdigest())
            else:
                sys.stdout.buffer.write(blob)

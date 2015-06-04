// Copyright 2014 Jean-Francois Roy. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be found in the LICENSE file.

#import "mhk/MHKLibAVIOContext.h"

#import "Base/RXErrorMacros.h"

#import "mhk/mohawk_libav.h"
#import "mhk/MHKErrors.h"
#import "mhk/MHKFileHandle.h"

static int MHKIOContextRead(MHKFileHandle* fh, uint8_t* buf, int buf_size) {
  debug_assert(buf_size >= 0);
  ssize_t bytes_read = [fh readDataOfLength:(size_t)buf_size inBuffer:buf error:NULL];
  return (int)bytes_read;
}

static int64_t MHKIOContextSeek(MHKFileHandle* fh, int64_t offset, int whence) {
  switch (whence) {
    case SEEK_SET:
      return [fh seekToFileOffset:offset];
    case SEEK_CUR:
      return [fh seekToFileOffset:fh.offsetInFile + offset];
    case AVSEEK_SIZE:
      return fh.length;
    default:
      abort();
  }
}

@implementation MHKLibAVIOContext

+ (void)initialize {
  if (self == [MHKLibAVIOContext class]) {
    mhk_load_libav();
  }
}

- (instancetype)init {
  [self doesNotRecognizeSelector:_cmd];
  return [self initWithFileHandle:nil error:NULL];
}

- (instancetype)initWithFileHandle:(MHKFileHandle*)fileHandle error:(NSError**)outError {
  self = [super init];
  if (!self) {
    return nil;
  }

  if (!g_libav.avu_handle) {
    [self release];
    ReturnValueWithError(nil, MHKErrorDomain, errLibavNotAvailable, nil, outError);
  }

  _fileHandle = [fileHandle retain];

  size_t iobuf_size = 0x1000;
  void* iobuf = g_libav.av_malloc(iobuf_size);

  _avioc = g_libav.avio_alloc_context(iobuf,
                                      (int)iobuf_size,
                                      0,
                                      (void*)_fileHandle,
                                      (int (*)(void*, uint8_t*, int))MHKIOContextRead,
                                      NULL,
                                      (int64_t (*)(void*, int64_t, int))MHKIOContextSeek);

  return self;
}

- (void)dealloc {
  [_fileHandle release];
  g_libav.av_freep(&_avioc->buffer);
  g_libav.av_freep(&_avioc);
  [super dealloc];
}

@end
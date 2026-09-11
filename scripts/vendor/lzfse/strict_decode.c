// Browser adapter for Apple's BSD-licensed decoder. Unlike the public buffer
// API, require the end marker AND full source consumption; never accept truncation.
#include "lzfse_internal.h"
#include <stdlib.h>
#include <string.h>

int ppomi_decode(unsigned char *dst, unsigned int capacity,
                 const unsigned char *src, unsigned int length) {
  lzfse_decoder_state *s = calloc(1, sizeof(*s));
  if (!s) return -4;
  s->src = s->src_begin = src;
  s->src_end = src + length;
  s->dst = s->dst_begin = dst;
  s->dst_end = dst + capacity;
  int status = lzfse_decode(s);
  int result = status == LZFSE_STATUS_DST_FULL ? -2 : -1;
  if (status == LZFSE_STATUS_OK && s->end_of_stream && s->src == s->src_end)
    result = (int)(s->dst - dst);
  memset(s, 0, sizeof(*s));
  free(s);
  return result;
}

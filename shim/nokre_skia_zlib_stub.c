// Windows link stub: FreeType's gzip support (ftgzip.obj, inside the
// prebuilt skia.lib) references the four plain-named zlib inflate
// entry points, but every zlib compiled into the prebuilt carries
// Chromium's Cr_z_ prefix — aseprite's own application supplies plain
// zlib, so the prebuilt leaves them undefined for the consumer.
//
// nokre never needs them to run: FT_Stream_OpenGzip / FT_Gzip_Uncompress
// only execute for gzip-compressed font streams (.gz fonts, WOFF), and
// the embedded faces are plain TTFs loaded from memory. Failing with
// Z_STREAM_ERROR makes any future gzipped stream a clean font-load
// error instead of an undefined symbol at link time.

#define NOKRE_Z_STREAM_ERROR (-2)

int inflateInit2_(void *strm, int window_bits, const char *version, int stream_size) {
    (void)strm;
    (void)window_bits;
    (void)version;
    (void)stream_size;
    return NOKRE_Z_STREAM_ERROR;
}

int inflate(void *strm, int flush) {
    (void)strm;
    (void)flush;
    return NOKRE_Z_STREAM_ERROR;
}

int inflateReset(void *strm) {
    (void)strm;
    return NOKRE_Z_STREAM_ERROR;
}

int inflateEnd(void *strm) {
    (void)strm;
    return NOKRE_Z_STREAM_ERROR;
}

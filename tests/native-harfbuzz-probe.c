/* Standalone musl load-order reproduction; requires a TrueType font path.
 * Run MODE(system-first|bundled-first|system-only) SYSTEM_SO SHARP_SO FONT_TTF.
 * Compile with cc -O0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -ldl. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char *font_data;
static size_t font_length;
static void *(*create_blob)(void *, unsigned, unsigned, void *, void *);
static unsigned be16(const unsigned char *p) { return (p[0] << 8) | p[1]; }
static unsigned be32(const unsigned char *p) { return ((unsigned)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }
static void *table(void *face, unsigned tag, void *data) {
    (void)face; (void)data;
    for (unsigned i = 0; i < be16(font_data + 4); i++) {
        const unsigned char *entry = font_data + 12 + i * 16;
        if (be32(entry) == tag) {
            unsigned offset = be32(entry + 8), length = be32(entry + 12);
            if ((size_t)offset + length > font_length) exit(3);
            return create_blob(font_data + offset, length, 1, NULL, NULL);
        }
    }
    return NULL;
}
static void *load(const char *file, int flags) {
    void *value = dlopen(file, flags);
    if (!value) { fprintf(stderr, "dlopen %s: %s\n", file, dlerror()); exit(2); }
    return value;
}
static void *symbol(void *library, const char *name) {
    void *value = dlsym(library, name);
    if (!value) { fprintf(stderr, "dlsym %s: %s\n", name, dlerror()); exit(2); }
    return value;
}
int main(int argc, char **argv) {
    if (argc != 5) return 2;
    setbuf(stdout, NULL);
    FILE *file = fopen(argv[4], "rb");
    if (!file) return 3;
    if (fseek(file, 0, SEEK_END)) return 3;
    long size = ftell(file);
    if (size < 12) return 3;
    font_length = (size_t)size;
    rewind(file);
    font_data = malloc(font_length);
    if (!font_data) return 3;
    if (fread(font_data, 1, font_length, file) != font_length) return 3;
    fclose(file);
    if (be16(font_data + 4) > (font_length - 12) / 16) return 3;
    void *library;
    if (!strcmp(argv[1], "system-first")) {
        load(argv[2], RTLD_NOW | RTLD_GLOBAL);
        library = load(argv[3], RTLD_NOW);
    } else if (!strcmp(argv[1], "bundled-first")) {
        library = load(argv[3], RTLD_NOW);
        load(argv[2], RTLD_NOW | RTLD_GLOBAL);
    } else if (!strcmp(argv[1], "system-only")) {
        library = load(argv[2], RTLD_NOW | RTLD_GLOBAL);
    } else return 2;
    const char *(*version)(void) = symbol(library, "hb_version_string");
    void *(*create_face)(void *, void *, void *) = symbol(library, "hb_face_create_for_tables");
    void (*set_upem)(void *, unsigned) = symbol(library, "hb_face_set_upem");
    void *(*create_font)(void *) = symbol(library, "hb_font_create");
    void (*destroy_font)(void *) = symbol(library, "hb_font_destroy");
    void (*destroy_face)(void *) = symbol(library, "hb_face_destroy");
    create_blob = symbol(library, "hb_blob_create");
    printf("%s loaded %s\n", argv[1], version());
    void *face = create_face((void *)table, NULL, NULL);
    printf("face %p\n", face);
    set_upem(face, 2048);
    void *font = create_font(face);
    printf("font %p\n", font);
    void (*set_funcs)(void *) = symbol(library, "hb_ot_font_set_funcs");
    void *(*create_buffer)(void) = symbol(library, "hb_buffer_create");
    void (*add_text)(void *, const char *, int, unsigned, int) = symbol(library, "hb_buffer_add_utf8");
    void (*guess)(void *) = symbol(library, "hb_buffer_guess_segment_properties");
    void (*shape)(void *, void *, const void *, unsigned) = symbol(library, "hb_shape");
    unsigned (*get_length)(void *) = symbol(library, "hb_buffer_get_length");
    void (*destroy_buffer)(void *) = symbol(library, "hb_buffer_destroy");
    set_funcs(font);
    for (unsigned i = 0; i < 1000; i++) {
        void *buffer = create_buffer();
        add_text(buffer, "Video Duplicate Finder office العربية", -1, 0, -1);
        guess(buffer);
        shape(font, buffer, NULL, 0);
        if (i == 0) printf("shaped %u glyphs\n", get_length(buffer));
        destroy_buffer(buffer);
    }
    destroy_font(font);
    destroy_face(face);
    free(font_data);
    puts("completed");
    return 0;
}

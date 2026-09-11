/* C ABI for TVMV's thumbnail card. See linux/src/capi.rs.
 *
 * The KDE thumbnail plugin links this so it draws the same card as the
 * freedesktop thumbnailer — one renderer, so a .md looks identical in Files,
 * Dolphin and Thunar. */
#ifndef TVMV_CARD_H
#define TVMV_CARD_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Render markdown to a PNG thumbnail. Returns NULL on failure; free the result
   with tvmv_card_free. `title` is the fallback used when the document has no
   heading, and may be NULL. `size` is clamped to 16..1024. */
unsigned char *tvmv_card_render_png(const unsigned char *markdown,
                                    size_t markdown_len, const char *title,
                                    int size, int dark, size_t *out_len);

void tvmv_card_free(unsigned char *ptr, size_t len);

#ifdef __cplusplus
}
#endif
#endif /* TVMV_CARD_H */

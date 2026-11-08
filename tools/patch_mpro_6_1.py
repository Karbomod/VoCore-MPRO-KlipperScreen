#!/usr/bin/env python3
"""Fail-closed Linux 6.1 compatibility / tested 0°-90° patch for Vonger/mpro_drm.

The input is the specific upstream mpro.c revision whose Git blob SHA is pinned.
Upstream copyright, SPDX identifier and license lines are preserved.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re

PINNED_UPSTREAM_BLOB = "f6cf32f5163004ed13e05ea9555ab523c3735c7a"


def blob_sha(content: bytes) -> str:
    return hashlib.sha1(
        f"blob {len(content)}\0".encode("ascii") + content
    ).hexdigest()


def patch(original: str, orientation: int) -> str:
    s = original

    def change(old: str, new: str, count: int = 1) -> None:
        nonlocal s
        actual = s.count(old)
        if actual != count:
            raise ValueError(f"Expected {count} occurrences, got {actual}: {old[:85]!r}")
        s = s.replace(old, new)

    def sub(pattern: str, replacement: str, count: int = 1) -> None:
        nonlocal s
        s, actual = re.subn(pattern, replacement, s, flags=re.M | re.S)
        if actual != count:
            raise ValueError(f"Expected {count} pattern matches, got {actual}: {pattern}")

    def replace_function(name: str, code: str) -> None:
        nonlocal s
        pattern = r"^static (?:int|void) " + name + r"\(.*?^\}"
        s, actual = re.subn(pattern, lambda _m: code.strip(), s, count=1, flags=re.M | re.S)
        if actual != 1:
            raise ValueError(f"Function not found exactly once: {name}")

    # Linux 6.1 DRM API compatibility, as tested on the reference Pi.
    change("#include <drm/drm_fbdev_ttm.h>\n", "")
    change("drm_fbdev_ttm_setup(dev, 0);", "drm_fbdev_generic_setup(dev, 0);")
    change(
        "struct drm_rect *clip, struct drm_format_conv_state *fmtcnv_state)",
        "struct drm_rect *clip)"
    )
    change(
        "struct drm_rect *rect, struct drm_format_conv_state *fmtcnv_stat)",
        "struct drm_rect *rect)"
    )
    change(
        "drm_fb_xrgb8888_to_rgb565(&dst_map, NULL, src_map, fb, clip, fmtcnv_state, false);",
        "drm_fb_xrgb8888_to_rgb565(&dst_map, NULL, src_map, fb, clip, false);"
    )
    change(
        "mpro_buf_copy(mpro->draw_buf, src, fb, rect, fmtcnv_stat);",
        "mpro_buf_copy(mpro->draw_buf, src, fb, rect);"
    )
    sub(
        r"mpro_fb_mark_dirty\(&shadow_plane_state->data\[0\],\s*fb,\s*&rect,\s*&shadow_plane_state->fmtcnv_state\);",
        "mpro_fb_mark_dirty(&shadow_plane_state->data[0], fb, &rect);",
        count=2
    )

    if orientation == 0:
        return s
    if orientation != 90:
        raise ValueError("Only 0 and 90 degrees are implemented and tested.")

    # True 90° driver-side rotation; physical screen remains 480x800.
    change("unsigned int height;", "unsigned int height;\n\tbool landscape;")
    change("unsigned char *draw_buf;", "unsigned char *draw_buf;\n\tunsigned char *rotate_buf;")
    change("model = MODEL_4IN;", "model = MODEL_4IN;\n\t\tmpro->landscape = true;")

    for field, old, new in (
        ("min_width", "width", "height"),
        ("max_width", "width", "height"),
        ("min_height", "height", "width"),
        ("max_height", "height", "width")
    ):
        change(
            f"dev->mode_config.{field} = {old};",
            f"dev->mode_config.{field} = mpro->landscape ? {new} : {old};"
        )

    for old, new in (
        ("width = mpro->width;", "width = mpro->landscape ? mpro->height : mpro->width;"),
        ("height = mpro->height;", "height = mpro->landscape ? mpro->width : mpro->height;"),
        ("width_mm = mpro->width_mm;", "width_mm = mpro->landscape ? mpro->height_mm : mpro->width_mm;"),
        ("height_mm = mpro->height_mm;", "height_mm = mpro->landscape ? mpro->width_mm : mpro->height_mm;")
    ):
        change(old, new)

    change(
        "mpro_edid.checksum = mpro_edid_block_checksum((u8*)&mpro_edid);",
        """if (mpro->landscape) {
        mpro_edid.detailed_timings[1].data.other_data.data.range.min_vfreq = 24;
        mpro_edid.detailed_timings[1].data.other_data.data.range.max_vfreq = 60;
        mpro_edid.detailed_timings[1].data.other_data.data.range.min_hfreq_khz = 15;
        mpro_edid.detailed_timings[1].data.other_data.data.range.max_hfreq_khz = 40;
    }
    mpro_edid.checksum = mpro_edid_block_checksum((u8*)&mpro_edid);"""
    )

    replace_function("mpro_data_alloc", r"""
static int mpro_data_alloc(struct mpro_device *mpro)
{
    size_t size = mpro->width * mpro->height * MPRO_BPP / 8 + mpro->margin;

    mpro->draw_buf = drmm_kmalloc(&mpro->dev, size, GFP_KERNEL);
    if (!mpro->draw_buf)
        return -ENOMEM;

    if (mpro->landscape) {
        mpro->rotate_buf = drmm_kmalloc(&mpro->dev, size, GFP_KERNEL);
        if (!mpro->rotate_buf)
            return -ENOMEM;
    }

    return 0;
}
""")

    replace_function("mpro_fb_mark_dirty", r"""
static void mpro_fb_mark_dirty(struct iosys_map *src,
                              struct drm_framebuffer *fb,
                              struct drm_rect *rect)
{
    struct mpro_device *mpro = to_mpro(fb->dev);
    int idx, ret, width, height, x0, y0, len;

    if (!drm_dev_enter(fb->dev, &idx))
        return;

    if (mpro->landscape) {
        u16 *in, *out;
        int x, y;

        if (fb->width != mpro->height ||
            fb->height != mpro->width) {
            ret = -EINVAL;
            goto done;
        }

        ret = mpro_buf_copy(mpro->rotate_buf, src, fb, rect);
        if (ret)
            goto done;

        width = rect->y2 - rect->y1;
        height = rect->x2 - rect->x1;
        x0 = rect->y1;
        y0 = mpro->height - rect->x2;

        in = (u16 *)mpro->rotate_buf;
        out = (u16 *)mpro->draw_buf;

        for (y = 0; y < height; y++) {
            for (x = 0; x < width; x++) {
                out[y * width + x] =
                    in[x * height + (height - 1 - y)];
            }
        }
    } else {
        ret = mpro_buf_copy(mpro->draw_buf, src, fb, rect);
        if (ret)
            goto done;

        x0 = rect->x1;
        y0 = rect->y1;
        width = rect->x2 - rect->x1;
        height = rect->y2 - rect->y1;
    }

    len = width * height * MPRO_BPP / 8;
    cmd_draw_part[6] = x0 & 0xff;
    cmd_draw_part[7] = (x0 >> 8) & 0xff;
    cmd_draw_part[8] = y0 & 0xff;
    cmd_draw_part[9] = (y0 >> 8) & 0xff;
    cmd_draw_part[10] = width & 0xff;
    cmd_draw_part[11] = (width >> 8) & 0xff;
    cmd_draw_part[2] = len & 0xff;
    cmd_draw_part[3] = (len >> 8) & 0xff;
    cmd_draw_part[4] = (len >> 16) & 0xff;

    ret = mpro_update_frame(mpro, len);

done:
    if (ret)
        dev_err_once(fb->dev->dev, "Failed to update display %d\n", ret);

    drm_dev_exit(idx);
}
""")

    change(
        "touch = (t->p[0].xh.x.f != 1) ? 1 : 0;",
        """touch = (t->p[0].xh.x.f != 1) ? 1 : 0;

    if (mpro->landscape) {
        int px = clamp(x, 0, (int)mpro->width - 1);
        int py = clamp(y, 0, (int)mpro->height - 1);
        x = mpro->height - 1 - py;
        y = px;
    }"""
    )
    change(
        "input_set_abs_params(mpro->input, ABS_X, 0, mpro->width, 0, 0);",
        "input_set_abs_params(mpro->input, ABS_X, 0, mpro->landscape ? mpro->height - 1 : mpro->width, 0, 0);"
    )
    change(
        "input_set_abs_params(mpro->input, ABS_Y, 0, mpro->height, 0, 0);",
        "input_set_abs_params(mpro->input, ABS_Y, 0, mpro->landscape ? mpro->width - 1 : mpro->height, 0, 0);"
    )
    if not all(key in s for key in ("mpro->landscape", "mpro->rotate_buf", "800")):
        # No literal '800' is required in the code; geometry is dynamic.
        if not ("mpro->landscape" in s and "mpro->rotate_buf" in s):
            raise ValueError("Landscape markers missing.")
    return s


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--orientation", type=int, choices=(0, 90), required=True)
    args = parser.parse_args()

    raw = args.source.read_bytes()
    actual_sha = blob_sha(raw)
    if actual_sha != PINNED_UPSTREAM_BLOB:
        raise SystemExit(
            "Upstream mpro.c version differs from the pinned source. "
            f"Expected {PINNED_UPSTREAM_BLOB}, got {actual_sha}. "
            "Stop: do not apply this patch to unknown driver versions."
        )
    patched = patch(raw.decode("utf-8"), args.orientation)
    if not patched.startswith("// SPDX-License-Identifier: GPL-2.0+"):
        raise SystemExit("Upstream licensing header changed; refusing to write.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(patched, encoding="utf-8")
    print(f"Patched Linux 6.1 M-PRO driver, orientation={args.orientation}°, output={args.output}")


if __name__ == "__main__":
    main()

# 从 gtmc-logo-1x.png 生成论坛的 SVG Logo、方形小 Logo 和各尺寸图标。
# 运行：uv run --with pillow python design/brand/build_icons.py
# 可重复执行，输出直接覆盖 design/brand/ 下的同名文件。上传到哪个站点设置见 infra/content/admin-setup.md。
from pathlib import Path

from PIL import Image

BRAND_DIR = Path(__file__).resolve().parent
LOGO_1X_PATH = BRAND_DIR / "gtmc-logo-1x.png"

# 方形图标就是 1x Logo 里的 G 字（含它自己的黑描边），占第 0–9 列、全部 13 行，原样裁下不重画。
G_LETTER_COLUMNS = range(0, 10)

# 应用图标在 iOS 和安卓上不能透明（iOS 会把透明区域填黑），所以垫一层底色。
# 取主题深色方案的 secondary，和论坛深色背景一致。
APP_ICON_BACKGROUND = (0x17, 0x1A, 0x17, 255)

# 每个 PNG：画布边长、每个 Logo 像素放大成几个屏幕像素、是否垫底色。
# 放大倍数必须是整数，像素才是方块。512 图的 G 字 240×312，四角离中心 197px，
# 落在安卓自适应图标 80% 安全圆（半径 204.8px）内，被系统裁成圆形也不会切到字。
PNG_ICONS = {
    "gtmc-favicon-32.png": (32, 2, False),
    "gtmc-apple-touch-icon-180.png": (180, 10, True),
    "gtmc-app-icon-512.png": (512, 24, True),
}


def read_pixels(image, columns):
    """返回 {(x, y): (r, g, b)}，只收不透明像素，x 从 0 重新编号。"""
    pixels = {}
    for new_x, x in enumerate(columns):
        for y in range(image.height):
            red, green, blue, alpha = image.getpixel((x, y))
            if alpha >= 128:
                pixels[(new_x, y)] = (red, green, blue)
    return pixels


def write_svg(path, pixels, view_box):
    # 同色的横向连续像素合成一个 rect，文件小一半以上；只用 svg/g/rect，都在 Discourse 上传清洗的白名单里。
    rects = []
    for (x, y), color in sorted(pixels.items(), key=lambda item: (item[0][1], item[0][0])):
        if pixels.get((x - 1, y)) == color:
            continue
        run_end = x + 1
        while pixels.get((run_end, y)) == color:
            run_end += 1
        rects.append(
            f'<rect x="{x}" y="{y}" width="{run_end - x}" height="1" fill="#{color[0]:02x}{color[1]:02x}{color[2]:02x}"/>'
        )
    min_x, min_y, width, height = view_box
    path.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{min_x} {min_y} {width} {height}" width="{width}" height="{height}">'
        f'<g shape-rendering="crispEdges">{"".join(rects)}</g></svg>\n'
    )


def write_png(path, pixels, art_width, art_height, canvas_size, scale, has_background):
    background = APP_ICON_BACKGROUND if has_background else (0, 0, 0, 0)
    canvas = Image.new("RGBA", (canvas_size, canvas_size), background)
    origin_x = (canvas_size - art_width * scale) // 2
    origin_y = (canvas_size - art_height * scale) // 2
    for (x, y), color in pixels.items():
        left = origin_x + x * scale
        top = origin_y + y * scale
        canvas.paste((*color, 255), (left, top, left + scale, top + scale))
    canvas.save(path, optimize=True)


def main():
    logo = Image.open(LOGO_1X_PATH).convert("RGBA")
    write_svg(BRAND_DIR / "gtmc-logo.svg", read_pixels(logo, range(logo.width)), (0, 0, logo.width, logo.height))

    letter_pixels = read_pixels(logo, G_LETTER_COLUMNS)
    letter_width = len(G_LETTER_COLUMNS)
    letter_height = logo.height

    # 核心把小 Logo 和完整 Logo 渲染成同一高度，所以小 Logo 的画布也取 13 格高，两者的像素才一样大。
    # 10 宽放进 13 宽的正方形差奇数格，用 viewBox 起点 -1.5 让 G 正好居中。
    square_size = letter_height
    horizontal_margin = (square_size - letter_width) / 2
    write_svg(BRAND_DIR / "gtmc-logo-small.svg", letter_pixels, (-horizontal_margin, 0, square_size, square_size))

    for file_name, (canvas_size, scale, has_background) in PNG_ICONS.items():
        write_png(
            BRAND_DIR / file_name,
            letter_pixels,
            letter_width,
            letter_height,
            canvas_size,
            scale,
            has_background,
        )


if __name__ == "__main__":
    main()

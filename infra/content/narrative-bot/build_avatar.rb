# frozen_string_literal: true

# 把 avatar.txt（像素网格）转成 avatar.png，供 infra/discourse/narrative_bot.rb 上传为引导机器人的头像。
# 用法（在仓库根目录）：ruby infra/content/narrative-bot/build_avatar.rb
# 只用 Ruby 标准库。PNG 逐像素放大，保持硬边。

require "zlib"

GRID_SIZE = 32
# 32 × 8 = 256 像素：论坛头像最大显示约 144 像素，核心上传时会再缩放，留足余量
SCALE = 8
GRID_PATH = File.join(__dir__, "avatar.txt")
PNG_PATH = File.join(__dir__, "avatar.png")
PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b

def read_grid(path)
  lines = File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }
  palette_lines, rows = lines.partition { |line| line.start_with?("@ ") }

  palette =
    palette_lines.to_h do |line|
      _marker, character, hex = line.split
      abort "#{path}: bad palette line #{line.inspect}" unless character&.size == 1 && hex&.match?(/\A\h{6}\z/)
      [character, [hex].pack("H*").bytes]
    end

  abort "#{path}: expected #{GRID_SIZE} rows, found #{rows.size}" unless rows.size == GRID_SIZE
  rows.each_with_index do |row, index|
    unless row.size == GRID_SIZE && row.each_char.all? { |character| palette.key?(character) }
      abort "#{path}: row #{index + 1} must be #{GRID_SIZE} characters from the palette"
    end
  end
  [rows, palette]
end

def png_chunk(type, data)
  [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
end

def scanlines(rows, palette)
  rows.flat_map do |row|
    scaled_row = [0] + row.each_char.flat_map { |character| palette.fetch(character) * SCALE }
    [scaled_row.pack("C*")] * SCALE
  end.join
end

rows, palette = read_grid(GRID_PATH)
size = GRID_SIZE * SCALE
# 位深 8、颜色类型 2（RGB）、无交错
header = [size, size, 8, 2, 0, 0, 0].pack("NNCCCCC")
png =
  PNG_SIGNATURE + png_chunk("IHDR".b, header) +
    png_chunk("IDAT".b, Zlib::Deflate.deflate(scanlines(rows, palette), Zlib::BEST_COMPRESSION)) +
    png_chunk("IEND".b, "".b)
File.binwrite(PNG_PATH, png)
puts "wrote #{PNG_PATH} (#{size}x#{size})"

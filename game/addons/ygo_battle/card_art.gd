class_name YgoCardArt
extends RefCounted
## Card faces shared by the battle screen and the deck preview: the card image from
## images_dir/<code>.jpg when it exists, otherwise a text face (name, level, ATK/DEF).

const SIZE := Vector2(68, 99)
const TYPE_MONSTER := 0x1
const TYPE_LINK := 0x4000000

static var _textures := {} ## "<images_dir>/<code>" -> Texture2D or null


static func texture(code: int, images_dir: String) -> Texture2D:
	var key := images_dir.path_join(str(code))
	if not _textures.has(key):
		var tex: Texture2D = null
		var path := key + ".jpg"
		if FileAccess.file_exists(path):
			var image := Image.load_from_file(path)
			if image != null:
				image.resize(int(SIZE.x * 2), int(SIZE.y * 2), Image.INTERPOLATE_BILINEAR)
				tex = ImageTexture.create_from_image(image)
		_textures[key] = tex
	return _textures[key]


static func text_face(info: Dictionary) -> String:
	var s: String = info.get("name", str(info.get("code", "?")))
	var type: int = info.get("type", 0)
	if type & TYPE_MONSTER:
		var level := "LINK-%d" % info.level if type & TYPE_LINK else "★%d" % info.level
		s += "\n%s\n%s/%s" % [level, info.attack, "-" if type & TYPE_LINK else str(info.defense)]
	return s


## A SIZE-d face (image, or text when there is no image) that ignores the mouse.
static func face(info: Dictionary, images_dir: String) -> Control:
	var tex := texture(int(info.get("code", 0)), images_dir)
	var out: Control
	if tex != null:
		var rect := TextureRect.new()
		rect.texture = tex
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		out = rect
	else:
		var label := Label.new()
		label.text = text_face(info)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_font_size_override("font_size", 10)
		out = label
	out.size = SIZE
	out.custom_minimum_size = SIZE
	out.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return out

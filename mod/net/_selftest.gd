extends Node
## TEMPORARY build check. Registered as the last autoload so every other
## autoload identifier resolves, then compiles every .gd in the project.
## Delete this file and its autoload entry once the mod is stable.

func _ready() -> void:
	var failures: Array[String] = []
	var total: int = 0
	var stack: Array[String] = ["res://"]

	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		for d: String in DirAccess.get_directories_at(dir_path):
			if d.begins_with("."):
				continue
			stack.append(dir_path.path_join(d))
		for f: String in DirAccess.get_files_at(dir_path):
			if not f.ends_with(".gd"):
				continue
			var p: String = dir_path.path_join(f)
			total += 1
			if load(p) == null:
				failures.append(p)

	print("SELFTEST | compiled %d scripts" % total)
	for f: String in failures:
		print("SELFTEST FAIL | %s" % f)
	print("SELFTEST | %d failure(s)" % failures.size())
	get_tree().quit()

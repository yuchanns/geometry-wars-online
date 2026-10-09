local fs = require "bee.filesystem"
local bindir, destination, host, engine = ...
bindir, destination = fs.path(bindir), fs.path(destination)

local function copy(source, target)
	fs.create_directories(target:parent_path())
	fs.copy_file(source, target, fs.copy_options.overwrite_existing)
end

local function copy_game(directory)
	for source in fs.pairs(directory) do
		if fs.is_directory(source) then
			copy_game(source)
		else
			copy(source, destination / source)
		end
	end
end

fs.remove_all(destination)
fs.create_directories(destination)
copy(fs.path(engine), destination / (host == "windows" and "soluna.exe" or "soluna"))
local module = host == "windows" and "websocket.dll" or "websocket.so"
copy(bindir / module, destination / module)
copy_game(fs.path "game")

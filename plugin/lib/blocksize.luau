--!strict
-- The height of a plugin block. Tern starts a block at 80x24 and, while its
-- window is in the background (behind other apps' windows), sends the pane's
-- real size only once the window is activated (Tern 0.9.8): until then the
-- block reads 80x24, whatever the pane's size.

local M = {}

M.SPAWN_COLS = 80
M.SPAWN_ROWS = 24
-- Lines of a pane as tall as Tern's default 1280x800 window.
M.DEFAULT_WINDOW_ROWS = 45

-- Lines to size the block's lists for: the pane's height, or a pane of
-- Tern's default window while the block still has its spawn size.
function M.rows(cols: number, rows: number): number
	if cols == M.SPAWN_COLS and rows == M.SPAWN_ROWS then
		return M.DEFAULT_WINDOW_ROWS
	end
	return rows
end

return M

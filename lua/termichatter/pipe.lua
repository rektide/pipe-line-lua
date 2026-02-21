--- Pipe: a first-class sequence of segment
--- The connected array of segment with rev, splice, clone, and splice_journal
local M = {}

--- Create a new pipe from an array of segment entry
---@param entry table Array of segment name or handler
---@return table pipe The pipe object (array + method)
function M.new(entry)
	local p = {}
	for i, e in ipairs(entry or {}) do
		p[i] = e
	end
	p.rev = 0
	p.splice_journal = {}

	--- Splice segment in the pipe (like JS Array.splice)
	--- Increments rev and records journal entry
	---@param startIndex number 1-based start position
	---@param deleteCount number Number of element to delete
	---@vararg any Segment element to insert
	---@return table[] deleted Array of deleted element
	function p:splice(startIndex, deleteCount, ...)
		local new = { ... }
		local deleted = {}
		for i = 1, deleteCount do
			local idx = startIndex + i - 1
			if self[idx] then
				table.insert(deleted, self[idx])
			end
		end
		for _ = 1, deleteCount do
			table.remove(self, startIndex)
		end
		for i, seg in ipairs(new) do
			table.insert(self, startIndex + i - 1, seg)
		end
		self.rev = self.rev + 1
		table.insert(self.splice_journal, {
			rev = self.rev,
			start = startIndex,
			deleted = deleteCount,
			inserted = #new,
		})
		return deleted
	end

	--- Clone this pipe into an independent copy
	---@return table pipe New pipe with same segment, own rev
	function p:clone()
		local c = M.new(self)
		c.rev = self.rev
		return c
	end

	return p
end

return M

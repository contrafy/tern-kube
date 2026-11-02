--!strict
-- What one object looks like for a cross-cluster comparison: the export
-- cleanup (gitops/clean) drops exactly the fields that differ between two
-- clusters holding identical objects (status, uid, resourceVersion, allocated
-- IPs, last-applied, ...). Unlike export, Secret values are kept so equal and
-- different Secrets can be told apart (the diff masks them afterwards), and
-- objects Kubernetes creates on its own are compared like any other.

local Clean = require("../gitops/clean")

local M = {}

local OPTIONS: Clean.Options = table.freeze({ secretValues = "keep" :: "keep", skipDefaults = false })

-- Pure: returns a cleaned deep copy, the input is never modified.
function M.normalize(obj: any): any
	if type(obj) ~= "table" then
		return obj
	end
	return (Clean.clean(obj, OPTIONS))
end

return M

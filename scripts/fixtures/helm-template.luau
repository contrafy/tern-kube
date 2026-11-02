--!strict
-- Prints the extras template the plugin passes to `helm get all --template`,
-- so capture-helm.sh records exactly what the plugin parses.
local Query = require("../../plugin/lib/helm/query")
print(Query.EXTRAS_TEMPLATE)

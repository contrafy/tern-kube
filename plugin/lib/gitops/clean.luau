--!strict
-- Turns a live object (`kubectl get -o json`) into the manifest a user would
-- have written: server-populated bookkeeping is dropped so re-applying the
-- export neither fights the API server (uid/resourceVersion conflicts,
-- immutable allocated fields) nor carries runtime state into git. Secrets
-- never leave the cluster: their values become placeholders.

type Object = { [string]: any }

export type Note = { severity: "info" | "warning", code: string, text: string }

export type Options = {
	placeholder: string?,
}

local PLACEHOLDER = "REPLACE_ME"
local SECRET_COMMENT = "tern-kube: secret values redacted; populate via SOPS/SealedSecrets/ExternalSecrets"

local METADATA_DROP: { string } = {
	"uid",
	"resourceVersion",
	"generation",
	"creationTimestamp",
	"managedFields",
	"selfLink",
	"deletionTimestamp",
	"deletionGracePeriodSeconds",
}

local ANNOTATIONS_DROP: { string } = {
	"kubectl.kubernetes.io/last-applied-configuration",
	"deployment.kubernetes.io/revision",
	-- PVC binding state written by the PV controller.
	"pv.kubernetes.io/bind-completed",
	"pv.kubernetes.io/bound-by-controller",
	"volume.beta.kubernetes.io/storage-provisioner",
	"volume.kubernetes.io/storage-provisioner",
	"volume.kubernetes.io/selected-node",
}

local RESTARTED_AT = "kubectl.kubernetes.io/restartedAt"

-- Labels the Job controller stamps on the selector and pod template.
local JOB_LABELS: { string } = {
	"controller-uid",
	"batch.kubernetes.io/controller-uid",
	"job-name",
	"batch.kubernetes.io/job-name",
}

-- Empty tables are shared, not copied: JSON array tags (`[]` vs `{}`) live on
-- the table identity, and clean never writes into an empty table.
local function deepCopy(v: any): any
	if type(v) ~= "table" or next(v) == nil then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

local function map(v: any): Object?
	return if type(v) == "table" then v else nil
end

local function note(notes: { Note }, severity: "info" | "warning", code: string, text: string)
	table.insert(notes, { severity = severity, code = code, text = text })
end

local function dropKeys(t: Object?, keys: { string })
	if t then
		for _, k in keys do
			t[k] = nil
		end
	end
end

local function dropIfEmpty(parent: Object, key: string)
	local v = parent[key]
	if type(v) == "table" and next(v) == nil then
		parent[key] = nil
	end
end

local EMPTY: Object = table.freeze({})

local function isCore(obj: Object): boolean
	return obj.apiVersion == "v1"
end

-- Reason the whole object is skipped: objects Kubernetes creates in every
-- namespace or derives from other objects.
local function skipReason(obj: Object): string?
	local metadata = map(obj.metadata) or EMPTY
	local kind: string = if type(obj.kind) == "string" then obj.kind else ""
	local name = metadata.name
	if kind == "ConfigMap" and isCore(obj) and name == "kube-root-ca.crt" then
		return "kube-root-ca.crt is published into every namespace by the API server"
	elseif kind == "ServiceAccount" and isCore(obj) and name == "default" then
		return "the default ServiceAccount is created in every namespace"
	elseif kind == "Secret" and isCore(obj) and obj.type == "kubernetes.io/service-account-token" then
		return "service-account token Secrets are populated by the token controller"
	elseif (kind == "Endpoints" and isCore(obj)) or kind == "EndpointSlice" then
		local labels = map(metadata.labels) or EMPTY
		if kind == "Endpoints" or labels["endpointslice.kubernetes.io/managed-by"] ~= nil then
			return "endpoints are maintained by the endpoints controllers from Services"
		end
	end
	return nil
end

local function cleanAnnotations(metadata: Object, notes: { Note }, where: string)
	local annotations = map(metadata.annotations)
	if not annotations then
		return
	end
	dropKeys(annotations, ANNOTATIONS_DROP)
	if annotations[RESTARTED_AT] ~= nil then
		annotations[RESTARTED_AT] = nil
		note(notes, "info", "restarted-at", "dropped " .. RESTARTED_AT .. " from " .. where)
	end
	dropIfEmpty(metadata, "annotations")
end

local function cleanMetadata(obj: Object, notes: { Note })
	local metadata = map(obj.metadata)
	if not metadata then
		return
	end
	dropKeys(metadata, METADATA_DROP)
	local owners = metadata.ownerReferences
	if type(owners) == "table" and #owners > 0 then
		local owner = map(owners[1]) or EMPTY
		note(
			notes,
			"warning",
			"owned",
			string.format(
				"dropped ownerReferences (owned by %s/%s): normally managed through its owner",
				tostring(owner.kind),
				tostring(owner.name)
			)
		)
	end
	metadata.ownerReferences = nil
	local finalizers = metadata.finalizers
	if type(finalizers) == "table" and #finalizers > 0 then
		note(notes, "info", "finalizers", "kept finalizers: " .. table.concat(finalizers, ", "))
	end
	cleanAnnotations(metadata, notes, "metadata.annotations")
	if obj.kind == "Namespace" then
		local labels = map(metadata.labels)
		if labels then
			labels["kubernetes.io/metadata.name"] = nil
			dropIfEmpty(metadata, "labels")
		end
	end
end

local function cleanTemplate(template: Object?, notes: { Note }, where: string)
	local metadata = template and map(template.metadata)
	if metadata then
		metadata.creationTimestamp = nil
		cleanAnnotations(metadata, notes, where)
	end
end

local function cleanPodSpec(spec: Object?, notes: { Note })
	if not spec then
		return
	end
	local volumes = spec.volumes
	if type(volumes) ~= "table" then
		return
	end
	local injected: { [string]: true } = {}
	local kept = {}
	for _, v in volumes do
		local name = type(v) == "table" and v.name
		if type(name) == "string" and string.find(name, "^kube%-api%-access%-") and v.projected ~= nil then
			injected[name] = true
		else
			table.insert(kept, v)
		end
	end
	if next(injected) == nil then
		return
	end
	spec.volumes = if #kept > 0 then kept else nil
	for _, field in { "containers", "initContainers", "ephemeralContainers" } do
		for _, c in (if type(spec[field]) == "table" then spec[field] else {}) :: { any } do
			local mounts = type(c) == "table" and c.volumeMounts
			if type(mounts) == "table" then
				local keptMounts = {}
				for _, m in mounts do
					if not (type(m) == "table" and injected[m.name]) then
						table.insert(keptMounts, m)
					end
				end
				c.volumeMounts = if #keptMounts > 0 then keptMounts else nil
			end
		end
	end
	note(notes, "info", "api-access-volume", "dropped the injected kube-api-access service-account volume")
end

local function cleanService(spec: Object, notes: { Note })
	if spec.clusterIP ~= "None" then
		spec.clusterIP = nil
	end
	spec.clusterIPs = nil
	spec.healthCheckNodePort = nil
	if spec.ipFamilyPolicy == "SingleStack" then
		spec.ipFamilyPolicy = nil
		spec.ipFamilies = nil
	end
	if spec.type == "NodePort" or spec.type == "LoadBalancer" then
		note(notes, "warning", "node-ports", "kept nodePort values; remove them unless they were chosen explicitly")
	end
end

local function cleanJob(spec: Object, notes: { Note })
	if spec.manualSelector == true then
		return
	end
	spec.selector = nil
	local template = map(spec.template)
	local metadata = template and map(template.metadata)
	local labels = metadata and map(metadata.labels)
	if metadata and labels then
		dropKeys(labels, JOB_LABELS)
		dropIfEmpty(metadata, "labels")
	end
	note(notes, "info", "job-selector", "dropped the generated Job selector and controller-uid labels")
end

local function redactSecret(obj: Object, placeholder: string, notes: { Note })
	local values: Object = {}
	local count = 0
	for _, field in { "data", "stringData" } do
		local source = map(obj[field])
		if source then
			for k in source do
				values[k] = placeholder
				count += 1
			end
		end
		obj[field] = nil
	end
	-- Placeholders go to stringData: `data` must hold base64 and the API
	-- server would reject a literal placeholder there.
	if count > 0 then
		obj.stringData = values
	end
	note(
		notes,
		"warning",
		"secret-redacted",
		string.format("replaced %d secret value(s) with %s; populate them out of band", count, placeholder)
	)
end

local function clean(input: Object, opts: Options?): (Object?, { Note })
	local notes: { Note } = {}
	local reason = skipReason(input)
	if reason then
		note(notes, "info", "skipped", reason)
		return nil, notes
	end
	local obj: Object = deepCopy(input)
	obj.status = nil
	cleanMetadata(obj, notes)
	local spec = map(obj.spec)
	local kind = obj.kind
	if spec then
		cleanTemplate(map(spec.template), notes, "spec.template")
		cleanPodSpec(map((map(spec.template) or EMPTY).spec), notes)
		local jobTemplate = map(spec.jobTemplate)
		if jobTemplate then
			cleanTemplate(jobTemplate, notes, "spec.jobTemplate")
			cleanTemplate(map((map(jobTemplate.spec) or EMPTY).template), notes, "spec.jobTemplate.spec.template")
		end
		if kind == "Pod" then
			cleanPodSpec(spec, notes)
			if spec.nodeName ~= nil then
				spec.nodeName = nil
				note(notes, "info", "node-name", "dropped spec.nodeName assigned by the scheduler")
			end
		elseif kind == "Service" and isCore(obj) then
			cleanService(spec, notes)
		elseif kind == "PersistentVolumeClaim" and isCore(obj) and spec.volumeName ~= nil then
			spec.volumeName = nil
			note(notes, "info", "volume-name", "dropped spec.volumeName bound by the PV controller")
		elseif kind == "Namespace" and isCore(obj) then
			spec.finalizers = nil
			dropIfEmpty(obj, "spec")
		elseif kind == "Job" and obj.apiVersion == "batch/v1" then
			cleanJob(spec, notes)
		end
	end
	if kind == "Secret" and isCore(obj) then
		redactSecret(obj, (opts and opts.placeholder) or PLACEHOLDER, notes)
	end
	return obj, notes
end

return {
	clean = clean,
	PLACEHOLDER = PLACEHOLDER,
	SECRET_COMMENT = SECRET_COMMENT,
}

--!strict
--[[
	Reflection.luau

	Encoding needs to know, for each class, *which* properties exist, what
	their serialized names are, and what binary type each one uses. Roblox
	exposes no runtime reflection for this, so this module provides three
	layers, consulted in order:

	  1. An API dump you supply (`Reflection.loadApiDump`). This is the
	     authoritative source — see the README for how to fetch one.
	  2. A built-in table of descriptors, resolved by `IsA` so that any
	     subclass inherits its ancestors' properties (a MeshPart picks up
	     everything registered for BasePart).
	  3. Runtime probing: anything in the built-in table that reads back
	     successfully on the live instance is kept, anything that errors is
	     dropped. This is what makes the module tolerant of Roblox removing
	     or renaming properties out from under it.

	Serialized names are not always the name you use from Lua. `BasePart.Size`
	is stored as `size`, `BasePart.Color` is stored as `Color3uint8`, and so
	on. Those quirks are baked into the table below.
]]

local DataTypes = require(script.Parent.DataTypes)

local TypeId = DataTypes.TypeId

export type Descriptor = {
	name: string, -- name used from Lua
	serialized: string, -- name written into the PROP chunk
	typeId: number,
	skipDefault: boolean?,
}

local Reflection = {}

-- --------------------------------------------------------------- built-ins

-- Shorthand: propName = "TypeName", or propName = { "TypeName", "SerializedName" }
type Spec = { [string]: string | { string } }

local CLASSES: { [string]: Spec } = {
	Instance = {
		Name = "String",
		Tags = "String",
		AttributesSerialize = "String",
		SourceAssetId = "Int64",
	},

	BasePart = {
		Anchored = "Bool",
		AssemblyLinearVelocity = { "Vector3", "AssemblyLinearVelocity" },
		AssemblyAngularVelocity = { "Vector3", "AssemblyAngularVelocity" },
		BackSurface = "Enum",
		BottomSurface = "Enum",
		BrickColor = { "BrickColor", "BrickColor" },
		CanCollide = "Bool",
		CanQuery = "Bool",
		CanTouch = "Bool",
		CastShadow = "Bool",
		CFrame = "CFrame",
		CollisionGroup = "String",
		Color = { "Color3uint8", "Color3uint8" },
		CustomPhysicalProperties = { "PhysicalProperties", "CustomPhysicalProperties" },
		EnableFluidForces = "Bool",
		FrontSurface = "Enum",
		LeftSurface = "Enum",
		Locked = "Bool",
		Massless = "Bool",
		Material = "Enum",
		MaterialVariant = "String",
		PivotOffset = "CFrame",
		Reflectance = "Float32",
		RightSurface = "Enum",
		RootPriority = "Int32",
		Size = { "Vector3", "size" },
		TopSurface = "Enum",
		Transparency = "Float32",
	},

	Part = {
		Shape = { "Enum", "shape" },
	},

	FormFactorPart = {
		FormFactor = { "Enum", "formFactorRaw" },
	},

	TriangleMeshPart = {
		CollisionFidelity = "Enum",
	},

	MeshPart = {
		DoubleSided = "Bool",
		MeshId = "String",
		RenderFidelity = "Enum",
		TextureID = "String",
	},

	Model = {
		LevelOfDetail = "Enum",
		ModelStreamingMode = "Enum",
		PrimaryPart = "Referent",
		WorldPivotData = { "OptionalCFrame", "WorldPivotData" },
	},

	Attachment = {
		CFrame = "CFrame",
		Visible = "Bool",
	},

	JointInstance = {
		C0 = "CFrame",
		C1 = "CFrame",
		Part0 = { "Referent", "Part0" },
		Part1 = { "Referent", "Part1" },
		Enabled = "Bool",
	},

	Motor6D = {
		CurrentAngle = "Float32",
		DesiredAngle = "Float32",
		MaxVelocity = "Float32",
		Transform = "CFrame",
	},

	Constraint = {
		Attachment0 = "Referent",
		Attachment1 = "Referent",
		Color = "BrickColor",
		Enabled = "Bool",
		Visible = "Bool",
	},

	LuaSourceContainer = {
		Source = { "String", "Source" },
	},

	Script = {
		Disabled = "Bool",
		Enabled = "Bool",
		RunContext = "Enum",
		LinkedSource = "String",
	},

	ValueBase = {},
	StringValue = { Value = "String" },
	BoolValue = { Value = "Bool" },
	IntValue = { Value = "Int64" },
	NumberValue = { Value = "Float64" },
	ObjectValue = { Value = "Referent" },
	CFrameValue = { Value = "CFrame" },
	Vector3Value = { Value = "Vector3" },
	Color3Value = { Value = "Color3" },
	BrickColorValue = { Value = "BrickColor" },
	RayValue = { Value = "Ray" },

	GuiBase2d = {
		AutoLocalize = "Bool",
		RootLocalizationTable = "Referent",
	},

	GuiObject = {
		Active = "Bool",
		AnchorPoint = "Vector2",
		AutomaticSize = "Enum",
		BackgroundColor3 = "Color3",
		BackgroundTransparency = "Float32",
		BorderColor3 = "Color3",
		BorderMode = "Enum",
		BorderSizePixel = "Int32",
		ClipsDescendants = "Bool",
		LayoutOrder = "Int32",
		Position = "UDim2",
		Rotation = "Float32",
		Selectable = "Bool",
		Size = "UDim2",
		SizeConstraint = "Enum",
		Visible = "Bool",
		ZIndex = "Int32",
	},

	TextLabel = {
		Font = "Enum",
		FontFace = "Font",
		LineHeight = "Float32",
		RichText = "Bool",
		Text = "String",
		TextColor3 = "Color3",
		TextScaled = "Bool",
		TextSize = "Float32",
		TextStrokeColor3 = "Color3",
		TextStrokeTransparency = "Float32",
		TextTransparency = "Float32",
		TextTruncate = "Enum",
		TextWrapped = "Bool",
		TextXAlignment = "Enum",
		TextYAlignment = "Enum",
	},

	ImageLabel = {
		Image = "String",
		ImageColor3 = "Color3",
		ImageRectOffset = "Vector2",
		ImageRectSize = "Vector2",
		ImageTransparency = "Float32",
		ResampleMode = "Enum",
		ScaleType = "Enum",
		SliceCenter = "Rect",
		SliceScale = "Float32",
		TileSize = "UDim2",
	},

	ScreenGui = {
		DisplayOrder = "Int32",
		Enabled = "Bool",
		IgnoreGuiInset = "Bool",
		ResetOnSpawn = "Bool",
		ZIndexBehavior = "Enum",
	},

	UIComponent = {},
	UICorner = { CornerRadius = "UDim" },
	UIPadding = {
		PaddingBottom = "UDim",
		PaddingLeft = "UDim",
		PaddingRight = "UDim",
		PaddingTop = "UDim",
	},
	UIStroke = {
		ApplyStrokeMode = "Enum",
		Color = "Color3",
		LineJoinMode = "Enum",
		Thickness = "Float32",
		Transparency = "Float32",
	},

	Decal = {
		Color3 = "Color3",
		Face = "Enum",
		Texture = "String",
		Transparency = "Float32",
		ZIndex = "Int32",
	},

	Texture = {
		OffsetStudsU = "Float32",
		OffsetStudsV = "Float32",
		StudsPerTileU = "Float32",
		StudsPerTileV = "Float32",
	},

	SpecialMesh = {
		MeshId = "String",
		MeshType = "Enum",
		Offset = "Vector3",
		Scale = "Vector3",
		TextureId = "String",
		VertexColor = "Vector3",
	},

	Light = {
		Brightness = "Float32",
		Color = "Color3",
		Enabled = "Bool",
		Shadows = "Bool",
	},
	PointLight = { Range = "Float32" },
	SpotLight = { Angle = "Float32", Face = "Enum", Range = "Float32" },
	SurfaceLight = { Angle = "Float32", Face = "Enum", Range = "Float32" },

	Sound = {
		Looped = "Bool",
		PlaybackSpeed = "Float32",
		Playing = "Bool",
		RollOffMaxDistance = "Float32",
		RollOffMinDistance = "Float32",
		RollOffMode = "Enum",
		SoundGroup = "Referent",
		SoundId = "String",
		TimePosition = "Float64",
		Volume = "Float32",
	},

	ParticleEmitter = {
		Acceleration = "Vector3",
		Color = "ColorSequence",
		Drag = "Float32",
		EmissionDirection = "Enum",
		Enabled = "Bool",
		Lifetime = "NumberRange",
		LightEmission = "Float32",
		LightInfluence = "Float32",
		Orientation = "Enum",
		Rate = "Float32",
		Rotation = "NumberRange",
		RotSpeed = "NumberRange",
		Size = "NumberSequence",
		Speed = "NumberRange",
		SpreadAngle = "Vector2",
		Texture = "String",
		Transparency = "NumberSequence",
		ZOffset = "Float32",
	},

	Beam = {
		Attachment0 = "Referent",
		Attachment1 = "Referent",
		Color = "ColorSequence",
		CurveSize0 = "Float32",
		CurveSize1 = "Float32",
		Enabled = "Bool",
		FaceCamera = "Bool",
		LightEmission = "Float32",
		Segments = "Int32",
		Texture = "String",
		TextureLength = "Float32",
		TextureMode = "Enum",
		TextureSpeed = "Float32",
		Transparency = "NumberSequence",
		Width0 = "Float32",
		Width1 = "Float32",
	},

	Humanoid = {
		AutoRotate = "Bool",
		DisplayDistanceType = "Enum",
		Health = "Float32",
		HipHeight = "Float32",
		JumpPower = "Float32",
		MaxHealth = "Float32",
		MaxSlopeAngle = "Float32",
		NameDisplayDistance = "Float32",
		RigType = "Enum",
		WalkSpeed = "Float32",
	},

	Folder = {},
	Configuration = {},

	Tool = {
		CanBeDropped = "Bool",
		Enabled = "Bool",
		Grip = "CFrame",
		RequiresHandle = "Bool",
		TextureId = "String",
		ToolTip = "String",
	},

	Camera = {
		CFrame = "CFrame",
		CameraType = "Enum",
		FieldOfView = "Float32",
		Focus = "CFrame",
	},

	Terrain = {
		MaterialColors = "String",
		WaterColor = "Color3",
		WaterReflectance = "Float32",
		WaterTransparency = "Float32",
		WaterWaveSize = "Float32",
		WaterWaveSpeed = "Float32",
	},

	UnionOperation = {
		AssetId = "String",
		ChildData = { "SharedString", "ChildData" },
		MeshData = { "SharedString", "MeshData" },
		PhysicalConfigData = { "SharedString", "PhysicalConfigData" },
		UsePartColor = "Bool",
	},
}

-- Classes that Roblox marks as services, for the INST chunk's object format.
local SERVICE_CLASSES: { [string]: boolean } = {
	Workspace = true,
	Lighting = true,
	ReplicatedStorage = true,
	ReplicatedFirst = true,
	ServerScriptService = true,
	ServerStorage = true,
	StarterGui = true,
	StarterPack = true,
	StarterPlayer = true,
	SoundService = true,
	Chat = true,
	Players = true,
	Teams = true,
	TestService = true,
	Debris = true,
	CollectionService = true,
	InsertService = true,
	LocalizationService = true,
	MaterialService = true,
	TextChatService = true,
	VoiceChatService = true,
	Terrain = false,
}

function Reflection.isService(className: string): boolean
	return SERVICE_CLASSES[className] == true
end

-- ---------------------------------------------------------- normalisation

local function normalise(spec: Spec): { Descriptor }
	local out: { Descriptor } = {}
	for name, entry in spec do
		local typeName: string
		local serialized: string
		if type(entry) == "table" then
			typeName = entry[1]
			serialized = entry[2] or name
		else
			typeName = entry
			serialized = name
		end
		local id = TypeId[typeName]
		if not id then
			error(`Reflection: unknown type name "{typeName}" for property "{name}"`)
		end
		table.insert(out, { name = name, serialized = serialized, typeId = id })
	end
	table.sort(out, function(a, b)
		return a.serialized < b.serialized
	end)
	return out
end

local NORMALISED: { [string]: { Descriptor } } = {}
for className, spec in CLASSES do
	NORMALISED[className] = normalise(spec)
end

-- ------------------------------------------------------------- API dump

-- ValueType.Name (from the official API dump) -> our type name
local DUMP_TYPE_MAP: { [string]: string } = {
	string = "String",
	ProtectedString = "String",
	BinaryString = "String",
	Content = "String",
	ContentId = "String",
	bool = "Bool",
	int = "Int32",
	int64 = "Int64",
	float = "Float32",
	double = "Float64",
	UDim = "UDim",
	UDim2 = "UDim2",
	Ray = "Ray",
	Faces = "Faces",
	Axes = "Axes",
	BrickColor = "BrickColor",
	Color3 = "Color3",
	Color3uint8 = "Color3uint8",
	Vector2 = "Vector2",
	Vector3 = "Vector3",
	Vector3int16 = "Vector3int16",
	CFrame = "CFrame",
	OptionalCoordinateFrame = "OptionalCFrame",
	NumberSequence = "NumberSequence",
	ColorSequence = "ColorSequence",
	NumberRange = "NumberRange",
	Rect = "Rect",
	PhysicalProperties = "PhysicalProperties",
	SharedString = "SharedString",
	UniqueId = "UniqueId",
	Font = "Font",
	SecurityCapabilities = "SecurityCapabilities",
	Class = "Referent",
	Enum = "Enum",
}

local dumpDescriptors: { [string]: { Descriptor } }? = nil
local dumpSuperclass: { [string]: string } = {}

--[[
	Feeds in an official API dump (the decoded JSON table, i.e. the thing with
	a `Classes` array). Once loaded it takes priority over the built-in table.
]]
function Reflection.loadApiDump(dump: any)
	local byClass: { [string]: { Descriptor } } = {}
	dumpSuperclass = {}

	for _, class in dump.Classes do
		local list: { Descriptor } = {}
		dumpSuperclass[class.Name] = class.Superclass

		for _, member in class.Members do
			if member.MemberType ~= "Property" then
				continue
			end

			local serialization = member.Serialization
			if not serialization or not serialization.CanSave then
				continue
			end

			local tags = member.Tags
			if tags then
				local skip = false
				for _, tag in tags do
					if tag == "ReadOnly" or tag == "Deprecated" or tag == "NotScriptable" then
						skip = tag == "ReadOnly"
					end
				end
				if skip then
					continue
				end
			end

			local vt = member.ValueType
			local typeName: string?
			if vt.Category == "Enum" then
				typeName = "Enum"
			elseif vt.Category == "Class" then
				typeName = "Referent"
			else
				typeName = DUMP_TYPE_MAP[vt.Name]
			end

			if typeName and TypeId[typeName] then
				table.insert(list, {
					name = member.Name,
					serialized = (serialization.SerializedName or member.Name) :: string,
					typeId = TypeId[typeName],
				})
			end
		end

		table.sort(list, function(a, b)
			return a.serialized < b.serialized
		end)
		byClass[class.Name] = list
	end

	dumpDescriptors = byClass
end

function Reflection.hasApiDump(): boolean
	return dumpDescriptors ~= nil
end

function Reflection.clearApiDump()
	dumpDescriptors = nil
	dumpSuperclass = {}
end

-- ------------------------------------------------------------- resolution

local cache: { [string]: { Descriptor } } = {}

local function fromDump(className: string): { Descriptor }?
	local db = dumpDescriptors
	if not db then
		return nil
	end

	local merged: { [string]: Descriptor } = {}
	local cursor: string? = className
	local guard = 0
	while cursor and guard < 64 do
		local list = db[cursor]
		if list then
			for _, d in list do
				if merged[d.name] == nil then
					merged[d.name] = d
				end
			end
		end
		cursor = dumpSuperclass[cursor]
		guard += 1
	end

	if next(merged) == nil then
		return nil
	end

	local out = {}
	for _, d in merged do
		table.insert(out, d)
	end
	table.sort(out, function(a, b)
		return a.serialized < b.serialized
	end)
	return out
end

--[[
	Returns the descriptors that apply to a live instance, filtered down to
	the ones that actually read back without erroring.
]]
function Reflection.descriptorsFor(instance: Instance): { Descriptor }
	local className = instance.ClassName
	local cached = cache[className]
	if cached then
		return cached
	end

	local candidates: { [string]: Descriptor } = {}

	local dumped = fromDump(className)
	if dumped then
		for _, d in dumped do
			candidates[d.name] = d
		end
	else
		-- Built-in table, resolved via IsA so subclasses inherit.
		for dbClass, list in NORMALISED do
			local ok, isa = pcall(function()
				return instance:IsA(dbClass)
			end)
			if ok and isa then
				for _, d in list do
					if candidates[d.name] == nil then
						candidates[d.name] = d
					end
				end
			end
		end
	end

	-- Runtime filter: drop anything not readable on this class.
	local out: { Descriptor } = {}
	for name, d in candidates do
		if name == "AttributesSerialize" or name == "Tags" or name == "WorldPivotData" then
			-- synthesised by the encoder, never read directly
			table.insert(out, d)
			continue
		end
		local ok = pcall(function()
			return (instance :: any)[name]
		end)
		if ok then
			table.insert(out, d)
		end
	end

	table.sort(out, function(a, b)
		return a.serialized < b.serialized
	end)
	cache[className] = out
	return out
end

function Reflection.clearCache()
	table.clear(cache)
end

Reflection.CLASSES = CLASSES
Reflection.DUMP_TYPE_MAP = DUMP_TYPE_MAP

return Reflection

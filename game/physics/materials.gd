class_name PhysicsMaterials
extends RefCounted

static func track() -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.friction = 0.4
	m.bounce = 0.25
	return m

static func marble() -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.friction = 0.3
	m.bounce = 0.35
	return m

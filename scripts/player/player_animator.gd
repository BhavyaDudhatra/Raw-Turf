class_name PlayerAnimator
extends Node3D
## Stage 2 animation driver (Task 7B.7) — presentation only.
## Reads the parent PlayerController state every physics frame and selects
## clips on CharAnim. The controller stays authoritative for movement, physics,
## input, camera, and visibility; this script never writes velocity, position,
## yaw of the player root, controls_enabled, or any gameplay variable, and it
## never applies root motion (animations touch skeleton bones only).
##
## State-selection rules (all derived from actual physics state):
## - driving / controls off: neutral Idle (hidden with the player), latches reset.
## - grounded locomotion (Stage 3/M2): planar-speed-parameterized Walk /
##   Jog_Fwd / Sprint zones with rate scaling [0.8, 1.25] (see M2 note below;
##   Stage 2 used the controller's movement_mode for Sprint vs Walk instead).
## - grounded slow: Idle (loop) at or below 0.35 m/s, Walk (loop) from 0.5 m/s,
##   hold current inside the hysteresis band (no flicker).
## - takeoff edge (grounded -> airborne): Jump_Start one-shot if rising
##   (velocity.y > 0.5), else sustained Jump directly (walked off a ledge).
## - sustained airborne past TAKEOFF_WINDOW (0.35 s): Jump loop (validated);
##   falls back to holding Jump_Start only if Jump is missing (defensive).
## - landing edge (airborne -> grounded): Jump_Land one-shot (validated),
##   held up to LAND_HOLD_MAX (0.7 s), then locomotion. A new takeoff cancels
##   it immediately, so quick re-jumps stay responsive.
## - teleport > TELEPORT_SNAP (2.0 m in one frame: respawn/load reposition):
##   latches reset, snap straight to locomotion (no stale land one-shot).
## Facing: CharacterRoot turns toward travel direction with the exact law and
## rate the controller uses for the (now hidden) capsule mesh
## (atan2(-x,-z), 10/s, 0.5 m/s threshold). MHChar keeps its baked PI offset
## (faces -Z at CharacterRoot identity); the player root yaw is never touched.
## Timing assumptions: one-shot windows are frame-timer based; looping clips
## loop; clips are switched only on target change (never restarted per frame).
## Missing clips are detected once in _ready (single log line) with Idle-based
## fallbacks; unexpected errors are logged, never swallowed silently.
##
## Stage 3/M2 cadence mapping (Task 7B.11) — speed-parameterized locomotion:
## planar speed selects Walk / Jog_Fwd / Sprint with playback-rate scaling in
## [0.8, 1.25]; crossovers at 2.0 (Walk->Jog) and 4.5 (Jog->Sprint) sit away
## from the steady cruise speeds (walk 4.0, sprint 7.0) so cruise never rests
## on a switch edge; a +/-0.15 m/s hold band suppresses boundary dither.
## Rate laws (M1 v_clip midpoints Walk 0.73 / Jog ~2.0 / Sprint ~4.5 m/s):
##   Walk:   r = clamp(0.75 + 0.25*v)        -> 1.00 @1 m/s, 1.25 @2 m/s
##   Jog:    r = clamp(0.50 + 0.15*v)        -> 0.80 @2, 0.95 @3, 1.10 @4 m/s
##   Sprint: r = clamp(0.80 + 0.225*(v-4.5)) -> 0.80 @4.5, ~1.14 @6, 1.25 @~6.5+
## Walk cruise 4.0 therefore plays Jog_Fwd x1.10 by design (gait-energy rule:
## a Sprint pose at 4 m/s reads as a run; residual slide ~45% mid-estimate is
## accepted and documented). One-shot/air/driving/Idle rates stay 1.0;
## locomotion never blends into airborne states; root motion stays disabled.

const WALK_ENTER := 0.5
const IDLE_ENTER := 0.35
const TURN_MIN := 0.5
const TAKEOFF_WINDOW := 0.35
const LAND_HOLD_MAX := 0.7
const TELEPORT_SNAP := 2.0
const BLEND_LOCOMOTION := 0.2
const BLEND_ONESHOT := 0.15
const RATE_MIN := 0.8
const RATE_MAX := 1.25
const JOG_ENTER := 2.0
const SPRINT_ENTER := 4.5
const BLEND_HYST := 0.15

@onready var _player: CharacterBody3D = get_parent() as CharacterBody3D
@onready var _anim: AnimationPlayer = $CharAnim

var _has_idle := false
var _has_walk := false
var _has_jog := false
var _has_sprint := false
var _has_start := false
var _has_jump := false
var _has_land := false
var _was_airborne := false
var _air_time := 0.0
var _land_left := 0.0
var _last_pos := Vector3.ZERO
var _last_rate := 1.0
var _ready_done := false


func _ready() -> void:
	_has_idle = _anim.has_animation("Idle")
	_has_walk = _anim.has_animation("Walk")
	_has_jog = _anim.has_animation("Jog_Fwd")
	_has_sprint = _anim.has_animation("Sprint")
	_has_start = _anim.has_animation("Jump_Start")
	_has_jump = _anim.has_animation("Jump")
	_has_land = _anim.has_animation("Jump_Land")
	if not (_has_idle and _has_walk and _has_jog and _has_sprint and _has_start and _has_jump and _has_land):
		push_warning("PlayerAnimator: missing clips idle=%s walk=%s jog=%s sprint=%s start=%s jump=%s land=%s; using fallbacks." % [
			str(_has_idle), str(_has_walk), str(_has_jog), str(_has_sprint),
			str(_has_start), str(_has_jump), str(_has_land)])
	_last_pos = global_position
	_last_rate = 1.0
	_anim.speed_scale = 1.0
	_play("Idle", -1.0)
	_ready_done = true


func _physics_process(delta: float) -> void:
	if not _ready_done:
		return
	var mode := String(_player.get("movement_mode"))
	var controls := bool(_player.get("controls_enabled"))
	var vel: Vector3 = _player.velocity
	var planar := Vector2(vel.x, vel.z).length()
	# Teleport/respawn/load snap: never play a stale land one-shot.
	if global_position.distance_to(_last_pos) > TELEPORT_SNAP:
		_was_airborne = false
		_air_time = 0.0
		_land_left = 0.0
	_last_pos = global_position
	if not controls or mode == "driving":
		_was_airborne = false
		_air_time = 0.0
		_land_left = 0.0
		_set_rate(1.0)
		_play("Idle", -1.0)
		return
	if not _player.is_on_floor():
		_land_left = 0.0
		if not _was_airborne:
			_was_airborne = true
			_air_time = 0.0
			_set_rate(1.0)
			if vel.y > 0.5 and _has_start:
				_play("Jump_Start", BLEND_ONESHOT)
			else:
				_air_time = TAKEOFF_WINDOW
				_play(_air_clip(), BLEND_ONESHOT)
		else:
			_air_time += delta
			if _air_time >= TAKEOFF_WINDOW:
				_set_rate(1.0)
				_play(_air_clip(), BLEND_LOCOMOTION)
	else:
		if _was_airborne:
			_was_airborne = false
			_air_time = 0.0
			if _has_land:
				_set_rate(1.0)
				_play("Jump_Land", BLEND_ONESHOT)
				_land_left = minf(_anim.get_animation("Jump_Land").get_length(), LAND_HOLD_MAX)
			else:
				_land_left = 0.0
		if _land_left > 0.0:
			_land_left -= delta
			if _land_left <= 0.0:
				_land_left = 0.0
				_play_locomotion(planar)
		else:
			_play_locomotion(planar)
	# Face travel direction (visual subtree only; player root yaw untouched).
	if planar > TURN_MIN:
		rotation.y = lerp_angle(rotation.y, atan2(-vel.x, -vel.z), 1.0 - exp(-10.0 * delta))


func _play_locomotion(planar: float) -> void:
	var clip := _locomotion_clip(planar)
	_set_rate(_loco_rate(clip, planar))
	_play(clip, BLEND_LOCOMOTION)


func _locomotion_clip(planar: float) -> String:
	# Idle band + hysteresis thresholds (0.5/0.35) preserved from Stage 2.
	if planar <= IDLE_ENTER and _has_idle:
		return "Idle"
	if planar < WALK_ENTER:
		# Hysteresis band: hold the current locomotion clip to avoid flicker.
		var hold := _anim.current_animation
		if hold == "Walk" and _has_walk:
			return "Walk"
		if hold == "Jog_Fwd" and _has_jog:
			return "Jog_Fwd"
		if hold == "Sprint" and _has_sprint:
			return "Sprint"
		return "Idle"
	return _loco_clip(planar)


func _loco_clip(planar: float) -> String:
	# Base zone from planar speed; an adjacent-zone hold band (+/-BLEND_HYST)
	# prevents dither when cruising near a crossover. Missing-clip collapse
	# reuses real clips only (production res holds all three; verified).
	var base := "Walk"
	if planar >= SPRINT_ENTER:
		base = "Sprint"
	elif planar >= JOG_ENTER:
		base = "Jog_Fwd"
	if base == "Jog_Fwd" and not _has_jog:
		base = "Sprint" if planar >= SPRINT_ENTER else "Walk"
	if base == "Sprint" and not _has_sprint:
		base = "Jog_Fwd" if _has_jog else "Walk"
	if base == "Walk" and not _has_walk:
		base = "Idle"
	var cur := _anim.current_animation
	if cur == "Walk" and base == "Jog_Fwd" and planar < JOG_ENTER + BLEND_HYST:
		return "Walk"
	if cur == "Jog_Fwd" and base == "Walk" and planar > JOG_ENTER - BLEND_HYST:
		return "Jog_Fwd"
	if cur == "Jog_Fwd" and base == "Sprint" and planar < SPRINT_ENTER + BLEND_HYST:
		return "Jog_Fwd"
	if cur == "Sprint" and base == "Jog_Fwd" and planar > SPRINT_ENTER - BLEND_HYST:
		return "Sprint"
	return base


func _loco_rate(clip: String, planar: float) -> float:
	# Segmented linear laws; every branch is hard-clamped to [RATE_MIN,
	# RATE_MAX]. Non-locomotion clips always play at 1.0.
	match clip:
		"Walk":
			return clampf(0.75 + 0.25 * planar, RATE_MIN, RATE_MAX)
		"Jog_Fwd":
			return clampf(0.50 + 0.15 * planar, RATE_MIN, RATE_MAX)
		"Sprint":
			return clampf(0.80 + 0.225 * (planar - SPRINT_ENTER), RATE_MIN, RATE_MAX)
	return 1.0


func _set_rate(r: float) -> void:
	# Playback-rate only; never restarts the clip. Locomotion refreshes this
	# every physics frame from planar speed; one-shot/air/driving/Idle paths
	# reset it to 1.0 so cadence scaling never leaks into other states.
	if absf(r - _last_rate) > 0.001:
		_last_rate = r
		_anim.speed_scale = r


func _air_clip() -> String:
	if _has_jump:
		return "Jump"
	if _has_start:
		return "Jump_Start"
	return "Idle"


func _play(clip: String, blend: float) -> void:
	if not _anim.has_animation(clip):
		if clip != "Idle":
			push_warning("PlayerAnimator: clip missing at play time: " + clip)
		clip = "Idle"
		if not _anim.has_animation(clip):
			return
	if _anim.current_animation == clip and _anim.is_playing():
		return
	if blend < 0.0:
		_anim.play(clip)
	else:
		_anim.play(clip, blend)

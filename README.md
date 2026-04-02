# Roblox NPC AI System

This repo showcases a Roblox NPC architecture built around utility scoring, threat tracking, and stateful controllers. The intent is to demonstrate gameplay AI that could sit inside a live combat game, not just simple `MoveTo()` loops.

## What the repo demonstrates

- utility-driven state selection
- threat scores built from damage, distance, and decay
- leash logic so enemies do not chase forever
- path replanning with cooldown control
- per-NPC blackboard state
- centralized service for updating many agents

## Core behaviors

- `Patrol`
  Move around the spawn post while idle.
- `Chase`
  Pursue the highest-threat target.
- `Retreat`
  Back away when health is low.
- `Return`
  Reset to the post when the target leaves the leash zone.

## Why it is good portfolio code

Good Roblox AI is usually about systems:

- how an NPC chooses targets
- how often paths are recalculated
- how state transitions are controlled
- how performance is kept reasonable with multiple agents

That is what this repo focuses on.


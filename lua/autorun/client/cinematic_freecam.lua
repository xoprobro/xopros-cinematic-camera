if CLIENT then

    ------------------------------------------------------------
    -- STATE
    ------------------------------------------------------------

    local freeCam = false
    local camMode = "free" -- free, topdown, shoulder, orbit, path, static, chase, front, crane, dollyzoom, bonecam

    local camPos = Vector(0, 0, 0)
    local camAng = Angle(0, 0, 0)
    local camFOV = 90

    local camSpeed = 200
    local camRotSpeed = 90
    local smoothSpeed = 6

    local curOrigin = Vector(0, 0, 0)
    local curAngles = Angle(0, 0, 0)
    local curFOV = 90
    local viewInitialized = false

    local orbitAngle = 0
    local orbitRadius = 150
    local orbitHeight = 40
    local orbitSpeed = 30

    local dronePrevYaw = nil

    local sideScrollAxis = Vector(1, 0, 0)
    local sideScrollDistance = 200
    local sideScrollHeight = 40

    local shakeEnabled = false
    local shakeIntensity = 1.5

    local dutchTilt = 0

    local slowMoOrbit = false

    local afkEnabled = false
    local afkTimeout = 20
    local afkIdleTime = 0
    local afkActive = false
    local afkPrevBars = false
    local afkPrevHUD = false

    local afkShotEntity = nil
    local afkShotTimer = 0
    local afkShotDuration = 8
    local afkShotYaw = 0
    local afkShotDistStart = 150
    local afkShotDistEnd = 150
    local afkShotHeight = 0
    local afkShotDrift = 0
    local afkShotFOVStart = 65
    local afkShotFOVEnd = 65

    local dollyInitialized = false
    local dollyRefDistance = 200
    local dollyRefFOV = 90

    local boneCamIndex = nil

    local waypoints = {}
    local MAX_WAYPOINTS = 20
    local pathPlaying = false
    local pathIndex = 1
    local pathElapsed = 0
    local pathSegmentTime = 2
    local playbackSegments = {}

    local showBars = false
    local barHeight = 0.09
    local hideHUD = false
    local followPlayerPath = false
    local navRouting = false

    local function LerpVector(t, a, b)
        return a + (b - a) * t
    end

    local VALID_MODES = {
        free = true, topdown = true, shoulder = true, orbit = true,
        static = true, chase = true, front = true, crane = true, dollyzoom = true,
        drone = true, hero = true, sidescroll = true
    }

    local BODY_PARTS = {
        { label = "Head",       keys = { "head" },                       offset = Vector(2, 0, 10) },
        { label = "Chest",      keys = { "spine2", "chest", "spine1" },   offset = Vector(20, 0, 8) },
        { label = "Pelvis",     keys = { "pelvis" },                      offset = Vector(14, 0, 10) },
        { label = "Right Hand", keys = { "r_hand", "hand_r", "righthand" }, offset = Vector(5, 0, 0) },
        { label = "Left Hand",  keys = { "l_hand", "hand_l", "lefthand" },  offset = Vector(5, 0, 0) },
        { label = "Back",       keys = { "spine2", "spine1", "spine" },   offset = Vector(-22, 0, 10) },
        { label = "Right Foot", keys = { "r_foot", "foot_r" },            offset = Vector(0, 10, 10) },
        { label = "Left Foot",  keys = { "l_foot", "foot_l" },            offset = Vector(0, -10, 10) },
    }

    local boneCamOffset = Vector(0, 0, 0)

    local function FindBoneByKeywords(ply, keys)
        if not IsValid(ply) then return nil end
        local count = ply:GetBoneCount() or 0

        for _, k in ipairs(keys) do
            for i = 0, count - 1 do
                local name = ply:GetBoneName(i)
                if name then
                    local lower = string.lower(name)
                    if string.find(lower, k, 1, true) then
                        return i
                    end
                end
            end
        end

        return nil
    end

    local function GetShotCenter(ent)
        if not IsValid(ent) then return Vector(0, 0, 0) end

        if ent:IsPlayer() or ent:IsNPC() then
            return ent:GetPos() + Vector(0, 0, 40)
        end

        local ok, center = pcall(function() return ent:WorldSpaceCenter() end)
        if ok and center then return center end

        return ent:GetPos()
    end

    local function ClampShotToWalls(center, origin, ignoreEnt)
        local tr = util.TraceHull({
            start = center,
            endpos = origin,
            mins = Vector(-4, -4, -4),
            maxs = Vector(4, 4, 4),
            filter = { LocalPlayer(), ignoreEnt },
            mask = MASK_SOLID
        })

        if tr.Hit then
            local dist = math.max(center:Distance(tr.HitPos) - 8, 20)
            return center + (origin - center):GetNormalized() * dist
        end

        return origin
    end

    local function PickAFKShot(ply)
        local candidates = { ply }

        for _, ent in ipairs(ents.FindInSphere(ply:GetPos(), 2000)) do
            if IsValid(ent) and ent ~= ply then
                local cls = ent:GetClass()
                if ent:IsPlayer() or ent:IsNPC() or ent:IsVehicle()
                    or cls == "prop_physics" or cls == "prop_physics_multiplayer"
                    or cls == "prop_dynamic" or cls == "prop_ragdoll"
                    or ent.Base == "base_glide" then
                    table.insert(candidates, ent)
                end
            end
        end

        afkShotEntity = candidates[math.random(#candidates)]
        afkShotYaw = math.random(0, 359)
        afkShotDistStart = math.random(80, 220)
        afkShotDistEnd = math.random(80, 220)
        afkShotHeight = math.random(-10, 60)
        afkShotDrift = (math.random(0, 1) == 0 and -1 or 1) * math.random(3, 10)
        afkShotFOVStart = math.random(40, 90)
        afkShotFOVEnd = math.random(40, 90)
        afkShotTimer = 0

        local pickedDesc = IsValid(afkShotEntity) and (afkShotEntity == ply and "the player" or afkShotEntity:GetClass()) or "nothing"
        print("Cinematic Cam AFK: " .. (#candidates - 1) .. " other candidates found, watching " .. pickedDesc)
    end

    ------------------------------------------------------------
    -- NAV MESH PATHFINDING (A* over CNavArea graph)
    ------------------------------------------------------------

    local function ComputeNavPath(startPos, endPos)
        if not navmesh then return nil end

        local allAreas = navmesh.GetAllNavAreas()
        if not allAreas or #allAreas == 0 then return nil end

        local startArea = navmesh.GetNearestNavArea(startPos)
        local endArea = navmesh.GetNearestNavArea(endPos)
        if not IsValid(startArea) or not IsValid(endArea) then return nil end
        if startArea == endArea then return { startPos, endPos } end

        local openSet = { [startArea] = true }
        local cameFrom = {}
        local gScore = { [startArea] = 0 }
        local fScore = { [startArea] = startArea:GetCenter():Distance(endArea:GetCenter()) }

        local iterations = 0
        local MAX_ITERATIONS = 1500

        while next(openSet) do
            iterations = iterations + 1
            if iterations > MAX_ITERATIONS then return nil end

            local current, currentF = nil, math.huge
            for area in pairs(openSet) do
                local f = fScore[area] or math.huge
                if f < currentF then
                    current = area
                    currentF = f
                end
            end

            if current == endArea then
                local path = { endArea:GetCenter() }
                local node = current
                while cameFrom[node] do
                    node = cameFrom[node]
                    table.insert(path, 1, node:GetCenter())
                end
                table.insert(path, 1, startPos)
                table.insert(path, endPos)
                return path
            end

            openSet[current] = nil

            local adjacents = current:GetAdjacentAreas()
            for _, neighbor in pairs(adjacents) do
                if IsValid(neighbor) then
                    local tentativeG = (gScore[current] or math.huge) + current:GetCenter():Distance(neighbor:GetCenter())
                    if tentativeG < (gScore[neighbor] or math.huge) then
                        cameFrom[neighbor] = current
                        gScore[neighbor] = tentativeG
                        fScore[neighbor] = tentativeG + neighbor:GetCenter():Distance(endArea:GetCenter())
                        openSet[neighbor] = true
                    end
                end
            end
        end

        return nil
    end

    ------------------------------------------------------------
    -- BUILD PLAYBACK SEGMENTS (runs once when Play Path starts)
    ------------------------------------------------------------

    local function BuildPlaybackSegments()
        playbackSegments = {}

        for i = 1, #waypoints - 1 do
            local a, b = waypoints[i], waypoints[i + 1]
            local points = { a.pos, b.pos }

            if navRouting and not followPlayerPath then
                local navPath = ComputeNavPath(a.pos, b.pos)
                if navPath and #navPath >= 2 then
                    points = navPath
                else
                    print("No nav mesh route found for segment " .. i .. ", using a straight line instead")
                end
            end

            local cumDist = { 0 }
            for j = 2, #points do
                cumDist[j] = cumDist[j - 1] + points[j - 1]:Distance(points[j])
            end
            local total = cumDist[#cumDist]
            if total <= 0 then total = 1 end

            table.insert(playbackSegments, {
                points = points,
                cumDist = cumDist,
                total = total,
                time = math.max(a.time or pathSegmentTime, 0.1),
                angFrom = a.ang, angTo = b.ang,
                fovFrom = a.fov, fovTo = b.fov,
                playerFrom = a.playerPos, playerTo = b.playerPos,
            })
        end
    end

    ------------------------------------------------------------
    -- CONCOMMANDS
    ------------------------------------------------------------

    concommand.Add("cin_freecam_toggle", function()
        freeCam = not freeCam

        if freeCam then
            local ply = LocalPlayer()
            if IsValid(ply) then
                camPos = ply:EyePos()
                camAng = ply:EyeAngles()
            end
        else
            pathPlaying = false

            if slowMoOrbit then
                slowMoOrbit = false
                RunConsoleCommand("host_timescale", "1")
            end
        end

        print("Free Cam:", freeCam and "ON" or "OFF")
    end)

    concommand.Add("cin_cam_toggle_slowmo", function()
        slowMoOrbit = not slowMoOrbit
        RunConsoleCommand("host_timescale", slowMoOrbit and "0.3" or "1")
    end)

    concommand.Add("cin_cam_set_mode", function(ply, cmd, args)
        local mode = args[1]
        if not VALID_MODES[mode] then return end

        if slowMoOrbit and camMode == "orbit" and mode ~= "orbit" then
            slowMoOrbit = false
            RunConsoleCommand("host_timescale", "1")
        end

        camMode = mode
        pathPlaying = false

        local lp = LocalPlayer()

        if camMode == "free" then
            if IsValid(lp) then
                camPos = lp:EyePos()
                camAng = lp:EyeAngles()
            end
        elseif camMode == "orbit" then
            orbitAngle = 0
        elseif camMode == "dollyzoom" then
            dollyInitialized = false
            if IsValid(lp) then
                local eyeAng = lp:EyeAngles()
                camPos = lp:EyePos() - eyeAng:Forward() * 200
            end
        elseif camMode == "drone" then
            dronePrevYaw = nil
        elseif camMode == "sidescroll" then
            if IsValid(lp) then
                local right = lp:EyeAngles():Right()
                right.z = 0
                right:Normalize()
                sideScrollAxis = right
            end
        end

        print("Cinematic Cam mode:", camMode)
    end)

    concommand.Add("cin_cam_set_bone_part", function(ply, cmd, args)
        local label = args[1]
        local lp = LocalPlayer()
        if not IsValid(lp) then return end

        for _, part in ipairs(BODY_PARTS) do
            if part.label == label then
                local boneIndex = FindBoneByKeywords(lp, part.keys)
                if boneIndex then
                    boneCamIndex = boneIndex
                    boneCamOffset = part.offset
                    camMode = "bonecam"
                    pathPlaying = false
                    print("Bone Cam attached to: " .. label .. " (bone " .. boneIndex .. ")")
                else
                    print("Could not find a bone matching: " .. label)
                end
                return
            end
        end
    end)

    concommand.Add("cin_cam_toggle_bars", function()
        showBars = not showBars
    end)

    concommand.Add("cin_cam_toggle_hud", function()
        hideHUD = not hideHUD
    end)

    concommand.Add("cin_cam_add_waypoint", function()
        if #waypoints >= MAX_WAYPOINTS then
            print("Waypoint limit reached (" .. MAX_WAYPOINTS .. ")")
            return
        end

        local ply = LocalPlayer()
        local playerPos = IsValid(ply) and ply:GetPos() or camPos

        table.insert(waypoints, { pos = camPos, ang = camAng, fov = camFOV, time = pathSegmentTime, playerPos = playerPos })
        print("Waypoint added (" .. #waypoints .. "/" .. MAX_WAYPOINTS .. ")")
    end)

    concommand.Add("cin_cam_remove_waypoint", function()
        if #waypoints > 0 then
            table.remove(waypoints)
            print("Removed last waypoint (" .. #waypoints .. " remaining)")
        end
    end)

    concommand.Add("cin_cam_clear_waypoints", function()
        waypoints = {}
        print("Waypoints cleared")
    end)

    concommand.Add("cin_cam_play_path", function()
        if #waypoints < 2 then
            print("Need at least 2 waypoints to play a path")
            return
        end

        BuildPlaybackSegments()

        freeCam = true
        camMode = "path"
        pathPlaying = true
        pathIndex = 1
        pathElapsed = 0
    end)

    ------------------------------------------------------------
    -- INPUT (free + dolly zoom movement, arrow keys)
    ------------------------------------------------------------

    hook.Add("Think", "CinematicCam_Input", function()
        if not freeCam then return end
        if camMode ~= "free" and camMode ~= "dollyzoom" then return end

        local ft = FrameTime()

        if camMode == "free" then
            local altHeld = input.IsKeyDown(KEY_LALT) or input.IsKeyDown(KEY_RALT)

            if altHeld then
                if input.IsKeyDown(KEY_UP)    then camAng.p = camAng.p - camRotSpeed * ft end
                if input.IsKeyDown(KEY_DOWN)  then camAng.p = camAng.p + camRotSpeed * ft end
                if input.IsKeyDown(KEY_LEFT)  then camAng.y = camAng.y - camRotSpeed * ft end
                if input.IsKeyDown(KEY_RIGHT) then camAng.y = camAng.y + camRotSpeed * ft end
            else
                if input.IsKeyDown(KEY_UP)    then camPos = camPos + camAng:Forward() * camSpeed * ft end
                if input.IsKeyDown(KEY_DOWN)  then camPos = camPos - camAng:Forward() * camSpeed * ft end
                if input.IsKeyDown(KEY_LEFT)  then camPos = camPos - camAng:Right()   * camSpeed * ft end
                if input.IsKeyDown(KEY_RIGHT) then camPos = camPos + camAng:Right()  * camSpeed * ft end
            end
        else
            -- dolly zoom: movement only, angle is auto-aimed at the player elsewhere
            if input.IsKeyDown(KEY_UP)    then camPos = camPos + camAng:Forward() * camSpeed * ft end
            if input.IsKeyDown(KEY_DOWN)  then camPos = camPos - camAng:Forward() * camSpeed * ft end
            if input.IsKeyDown(KEY_LEFT)  then camPos = camPos - camAng:Right()   * camSpeed * ft end
            if input.IsKeyDown(KEY_RIGHT) then camPos = camPos + camAng:Right()  * camSpeed * ft end
        end

        if input.IsKeyDown(KEY_PAGEUP)   then camPos = camPos + Vector(0, 0, 1) * camSpeed * ft end
        if input.IsKeyDown(KEY_PAGEDOWN) then camPos = camPos - Vector(0, 0, 1) * camSpeed * ft end

        camAng.p = math.Clamp(camAng.p, -89, 89)
    end)

    ------------------------------------------------------------
    -- ORBIT MODE UPDATE
    ------------------------------------------------------------

    hook.Add("Think", "CinematicCam_Orbit", function()
        if not freeCam or camMode ~= "orbit" then return end
        orbitAngle = (orbitAngle + orbitSpeed * FrameTime()) % 360
    end)

    ------------------------------------------------------------
    -- AFK CAM (GTA-style idle takeover)
    ------------------------------------------------------------

    local afkLastPos = nil
    local afkLastAng = nil

    hook.Add("Think", "CinematicCam_AFKDetect", function()
        if not afkEnabled then return end

        local ply = LocalPlayer()
        if not IsValid(ply) then return end

        local pos = ply:GetPos()
        local ang = ply:EyeAngles()
        local moved = false

        if afkLastPos then
            if pos:DistToSqr(afkLastPos) > 4 then moved = true end
            if math.abs(math.AngleDifference(ang.y, afkLastAng.y)) > 0.5 then moved = true end
            if math.abs(math.AngleDifference(ang.p, afkLastAng.p)) > 0.5 then moved = true end
        end

        if input.IsKeyDown(KEY_W) or input.IsKeyDown(KEY_A) or input.IsKeyDown(KEY_S) or input.IsKeyDown(KEY_D)
            or input.IsKeyDown(KEY_SPACE) or input.IsMouseDown(MOUSE_LEFT) or input.IsMouseDown(MOUSE_RIGHT) then
            moved = true
        end

        afkLastPos = pos
        afkLastAng = ang

        if moved then
            afkIdleTime = 0
            if afkActive then
                afkActive = false
                afkShotEntity = nil
                showBars = afkPrevBars
                hideHUD = afkPrevHUD
            end
        else
            afkIdleTime = afkIdleTime + FrameTime()
            if afkIdleTime >= afkTimeout and not freeCam and not afkActive then
                afkActive = true
                afkPrevBars = showBars
                afkPrevHUD = hideHUD
                showBars = true
                hideHUD = true
            end
        end
    end)

    ------------------------------------------------------------
    -- WAYPOINT PATH PLAYBACK
    ------------------------------------------------------------

    hook.Add("Think", "CinematicCam_PathPlayback", function()
        if not pathPlaying or camMode ~= "path" then return end

        local seg = playbackSegments[pathIndex]
        if not seg then
            pathPlaying = false
            camMode = "free"
            return
        end

        pathElapsed = pathElapsed + FrameTime()
        local t = math.Clamp(pathElapsed / seg.time, 0, 1)

        local targetDist = t * seg.total
        local points, cumDist = seg.points, seg.cumDist
        local pos = points[#points]

        for k = 1, #points - 1 do
            if targetDist >= cumDist[k] and targetDist <= cumDist[k + 1] then
                local span = cumDist[k + 1] - cumDist[k]
                local segT = span > 0 and (targetDist - cumDist[k]) / span or 0
                pos = LerpVector(segT, points[k], points[k + 1])
                break
            end
        end

        if followPlayerPath then
            local ply = LocalPlayer()
            if IsValid(ply) then
                local anchor = LerpVector(t, seg.playerFrom, seg.playerTo)
                local offset = pos - anchor
                camPos = ply:GetPos() + offset
                camAng = (ply:EyePos() - camPos):Angle()
            else
                camPos = pos
                camAng = LerpAngle(t, seg.angFrom, seg.angTo)
            end
        else
            camPos = pos
            camAng = LerpAngle(t, seg.angFrom, seg.angTo)
        end

        camFOV = Lerp(t, seg.fovFrom, seg.fovTo)

        if t >= 1 then
            pathIndex = pathIndex + 1
            pathElapsed = 0

            if pathIndex > #playbackSegments then
                pathPlaying = false
                camMode = "free"
            end
        end
    end)

    ------------------------------------------------------------
    -- VIEW TARGET PER MODE
    ------------------------------------------------------------

    local function GetTargetView(ply)
        if camMode == "topdown" then
            local target = ply:GetPos() + Vector(0, 0, 40)
            return target + Vector(0, 0, 400), Angle(90, ply:EyeAngles().y, 0), 90

        elseif camMode == "shoulder" then
            local eyeAng = ply:EyeAngles()
            local origin = ply:GetPos() + Vector(0, 0, 60) - eyeAng:Forward() * 55 + eyeAng:Right() * 15
            return origin, eyeAng, 75

        elseif camMode == "orbit" then
            local center = ply:GetPos() + Vector(0, 0, orbitHeight)
            local rad = math.rad(orbitAngle)
            local offset = Vector(math.cos(rad), math.sin(rad), 0) * orbitRadius
            local origin = center + offset
            local ang = (center - origin):Angle()
            return origin, ang, camFOV

        elseif camMode == "chase" then
            local eyeAng = ply:EyeAngles()
            local origin = ply:GetPos() + Vector(0, 0, 55) - eyeAng:Forward() * 120
            return origin, eyeAng, 80

        elseif camMode == "front" then
            local eyeAng = ply:EyeAngles()
            local origin = ply:GetPos() + Vector(0, 0, 60) + eyeAng:Forward() * 90
            local ang = (ply:EyePos() - origin):Angle()
            return origin, ang, 80

        elseif camMode == "crane" then
            local eyeAng = ply:EyeAngles()
            local origin = ply:GetPos() + Vector(0, 0, 160) - eyeAng:Forward() * 160
            local lookAt = ply:GetPos() + Vector(0, 0, 40)
            local ang = (lookAt - origin):Angle()
            return origin, ang, 80

        elseif camMode == "drone" then
            local eyeAng = ply:EyeAngles()
            local speed = ply:GetVelocity():Length()
            local dist = 120 + math.Clamp(speed * 0.4, 0, 150)
            local origin = ply:GetPos() + Vector(0, 0, 90) - eyeAng:Forward() * dist

            dronePrevYaw = dronePrevYaw or eyeAng.y
            local yawDelta = math.AngleDifference(eyeAng.y, dronePrevYaw)
            dronePrevYaw = eyeAng.y
            local bank = math.Clamp(-yawDelta * 4, -25, 25)

            local lookAt = ply:GetPos() + Vector(0, 0, 40)
            local ang = (lookAt - origin):Angle()
            ang.r = bank

            return origin, ang, 85

        elseif camMode == "hero" then
            local eyeAng = ply:EyeAngles()
            local origin = ply:GetPos() + Vector(0, 0, 10) - eyeAng:Forward() * 70
            local lookAt = ply:GetPos() + Vector(0, 0, 60)
            local ang = (lookAt - origin):Angle()
            return origin, ang, 80

        elseif camMode == "sidescroll" then
            local origin = ply:GetPos() + sideScrollAxis * sideScrollDistance + Vector(0, 0, sideScrollHeight)
            local lookAt = ply:GetPos() + Vector(0, 0, 40)
            local ang = (lookAt - origin):Angle()
            return origin, ang, 70

        elseif camMode == "dollyzoom" then
            local eyePos = ply:EyePos()
            camAng = (eyePos - camPos):Angle()

            local distance = math.max(camPos:Distance(eyePos), 1)

            if not dollyInitialized then
                dollyRefDistance = distance
                dollyRefFOV = camFOV
                dollyInitialized = true
            end

            local halfRad = math.rad(dollyRefFOV / 2)
            local fov = math.deg(2 * math.atan((dollyRefDistance * math.tan(halfRad)) / distance))
            fov = math.Clamp(fov, 5, 170)

            return camPos, camAng, fov

        elseif camMode == "bonecam" then
            if boneCamIndex and IsValid(ply) then
                ply:SetupBones() -- force current-frame bone positions instead of last frame's
                local pos = ply:GetBonePosition(boneCamIndex)
                if pos then
                    local eyeAng = ply:EyeAngles()
                    local worldOffset = eyeAng:Forward() * boneCamOffset.x
                        + eyeAng:Right() * boneCamOffset.y
                        + eyeAng:Up() * boneCamOffset.z
                    return pos + worldOffset, eyeAng, camFOV
                end
            end
            return ply:EyePos(), ply:EyeAngles(), camFOV
        end

        -- "free", "static", "path" all just use the stored camPos/camAng/camFOV directly
        return camPos, camAng, camFOV
    end

    ------------------------------------------------------------
    -- SMOOTHED CAMERA OVERRIDE
    ------------------------------------------------------------

    hook.Add("CalcView", "CinematicCam_View", function(ply, pos, ang, fov)
        if not freeCam then
            viewInitialized = false

            if afkActive and IsValid(ply) then
                if not IsValid(afkShotEntity) then
                    PickAFKShot(ply)
                end

                afkShotTimer = afkShotTimer + FrameTime()
                if afkShotTimer >= afkShotDuration then
                    PickAFKShot(ply)
                end

                afkShotYaw = (afkShotYaw + afkShotDrift * FrameTime()) % 360

                local t = math.Clamp(afkShotTimer / afkShotDuration, 0, 1)
                local dist = Lerp(t, afkShotDistStart, afkShotDistEnd)
                local fov = Lerp(t, afkShotFOVStart, afkShotFOVEnd)

                local center = GetShotCenter(afkShotEntity)
                local rad = math.rad(afkShotYaw)
                local origin = center + Vector(math.cos(rad), math.sin(rad), 0) * dist + Vector(0, 0, afkShotHeight)
                origin = ClampShotToWalls(center, origin, afkShotEntity)
                local angle = (center - origin):Angle()

                return { origin = origin, angles = angle, fov = fov, drawviewer = true }
            end

            return
        end

        local targetOrigin, targetAngles, targetFOV = GetTargetView(ply)

        if camMode == "bonecam" then
            -- attached-to-body cameras should track in real time, no catch-up lag
            curOrigin = targetOrigin
            curAngles = targetAngles
            curFOV = targetFOV
            viewInitialized = true
        elseif not viewInitialized then
            curOrigin = targetOrigin
            curAngles = targetAngles
            curFOV = targetFOV
            viewInitialized = true
        else
            local frac = math.Clamp(smoothSpeed * FrameTime(), 0, 1)
            curOrigin = LerpVector(frac, curOrigin, targetOrigin)
            curAngles = LerpAngle(frac, curAngles, targetAngles)
            curFOV = Lerp(frac, curFOV, targetFOV)
        end

        local outOrigin = curOrigin
        local outAngles = Angle(curAngles.p, curAngles.y, curAngles.r + dutchTilt)

        if shakeEnabled then
            local t = RealTime()
            local ox = math.sin(t * 5.3) * shakeIntensity
            local oy = math.sin(t * 4.1 + 1.3) * shakeIntensity
            local oz = math.sin(t * 6.7 + 2.7) * shakeIntensity * 0.5

            outOrigin = outOrigin + Vector(ox * 0.3, oy * 0.3, oz * 0.3)
            outAngles = Angle(outAngles.p + oy * 0.15, outAngles.y + ox * 0.15, outAngles.r + oz * 0.2)
        end

        return {
            origin = outOrigin,
            angles = outAngles,
            fov = curFOV,
            drawviewer = true
        }
    end)

    ------------------------------------------------------------
    -- CINEMATIC BLACK BARS
    ------------------------------------------------------------

    hook.Add("HUDPaint", "CinematicCam_Bars", function()
        if not showBars then return end

        local h = ScrH() * barHeight
        surface.SetDrawColor(0, 0, 0, 255)
        surface.DrawRect(0, 0, ScrW(), h)
        surface.DrawRect(0, ScrH() - h, ScrW(), h)
    end)

    -- Keep the weapon selector alive so scroll-to-switch still works while hidden;
    -- CHudGMod is also exempt since it's what drives our own HUDPaint hook above.
    local HUD_HIDE_EXEMPT = {
        CHudGMod = true,
        CHudWeaponSelection = true,
    }

    hook.Add("HUDShouldDraw", "CinematicCam_HideHUD", function(name)
        if hideHUD and not HUD_HIDE_EXEMPT[name] then return false end
    end)

    ------------------------------------------------------------
    -- C-MENU ICON / POPUP UI
    ------------------------------------------------------------

    list.Set("DesktopWindows", "CinematicCamWindow", {
        title = "Cinematic Cam",
        icon = "icon16/camera.png",
        width = 340,
        height = 760,
        onewindow = true,
        init = function(icon, window)
            window:Center()

            local scroll = vgui.Create("DScrollPanel", window)
            scroll:Dock(FILL)

            local modelPanel = vgui.Create("DModelPanel", scroll)
            modelPanel:Dock(TOP)
            modelPanel:SetTall(200)
            modelPanel:DockMargin(10, 10, 10, 10)
            modelPanel:SetModel(LocalPlayer():GetModel())
            modelPanel:SetFOV(40)
            modelPanel:SetCamPos(Vector(50, 0, 60))
            modelPanel:SetLookAt(Vector(0, 0, 55))
            modelPanel.LayoutEntity = function(self, ent)
                ent:SetAngles(Angle(0, (RealTime() * 20) % 360, 0))
            end

            local function AddButton(text, onClick)
                local btn = vgui.Create("DButton", scroll)
                btn:Dock(TOP)
                btn:DockMargin(10, 0, 10, 5)
                btn:SetText(text)
                btn.DoClick = onClick
                return btn
            end

            local function AddSlider(label, minv, maxv, default, decimals, onChange)
                local slider = vgui.Create("DNumSlider", scroll)
                slider:Dock(TOP)
                slider:DockMargin(10, 0, 10, 5)
                slider:SetText(label)
                slider:SetMin(minv)
                slider:SetMax(maxv)
                slider:SetDecimals(decimals)
                slider:SetValue(default)
                slider.OnValueChanged = function(_, val) onChange(val) end
                return slider
            end

            local function AddHeader(text)
                local lbl = vgui.Create("DLabel", scroll)
                lbl:Dock(TOP)
                lbl:DockMargin(10, 12, 10, 2)
                lbl:SetFont("DermaDefaultBold")
                lbl:SetText(text)
                return lbl
            end

            AddButton("Toggle Camera On/Off", function() RunConsoleCommand("cin_freecam_toggle") end)

            AddHeader("Camera Mode")
            AddButton("Free Fly Cam", function() RunConsoleCommand("cin_cam_set_mode", "free") end)
            AddButton("Static Cam (locks in place)", function() RunConsoleCommand("cin_cam_set_mode", "static") end)
            AddButton("Top-Down View", function() RunConsoleCommand("cin_cam_set_mode", "topdown") end)
            AddButton("Shoulder View", function() RunConsoleCommand("cin_cam_set_mode", "shoulder") end)
            AddButton("Chase Cam", function() RunConsoleCommand("cin_cam_set_mode", "chase") end)
            AddButton("Front Cam", function() RunConsoleCommand("cin_cam_set_mode", "front") end)
            AddButton("Crane Cam", function() RunConsoleCommand("cin_cam_set_mode", "crane") end)
            AddButton("Orbit View", function() RunConsoleCommand("cin_cam_set_mode", "orbit") end)
            AddButton("Dolly Zoom (Vertigo)", function() RunConsoleCommand("cin_cam_set_mode", "dollyzoom") end)
            AddButton("Drone Follow Cam", function() RunConsoleCommand("cin_cam_set_mode", "drone") end)
            AddButton("Low-Angle Hero Cam", function() RunConsoleCommand("cin_cam_set_mode", "hero") end)
            AddButton("Side-Scroller Cam", function() RunConsoleCommand("cin_cam_set_mode", "sidescroll") end)

            AddHeader("Bone Cam (attach to body part)")
            for _, part in ipairs(BODY_PARTS) do
                AddButton(part.label, function() RunConsoleCommand("cin_cam_set_bone_part", part.label) end)
            end

            AddHeader("Settings")
            AddSlider("Move Speed", 50, 800, camSpeed, 0, function(v) camSpeed = v end)
            AddSlider("Rotate Speed", 30, 300, camRotSpeed, 0, function(v) camRotSpeed = v end)
            AddSlider("FOV", 30, 120, camFOV, 0, function(v) camFOV = v end)
            AddSlider("Smoothing", 1, 15, smoothSpeed, 1, function(v) smoothSpeed = v end)
            AddSlider("Orbit Radius", 50, 500, orbitRadius, 0, function(v) orbitRadius = v end)
            AddSlider("Orbit Speed", 5, 120, orbitSpeed, 0, function(v) orbitSpeed = v end)

            local barsCheck = vgui.Create("DCheckBoxLabel", scroll)
            barsCheck:Dock(TOP)
            barsCheck:DockMargin(10, 10, 10, 5)
            barsCheck:SetText("Cinematic Black Bars")
            barsCheck:SetValue(showBars)
            barsCheck.OnChange = function(_, val) showBars = val end

            local hudCheck = vgui.Create("DCheckBoxLabel", scroll)
            hudCheck:Dock(TOP)
            hudCheck:DockMargin(10, 0, 10, 5)
            hudCheck:SetText("Hide HUD")
            hudCheck:SetValue(hideHUD)
            hudCheck.OnChange = function(_, val) hideHUD = val end

            local shakeCheck = vgui.Create("DCheckBoxLabel", scroll)
            shakeCheck:Dock(TOP)
            shakeCheck:DockMargin(10, 0, 10, 5)
            shakeCheck:SetText("Handheld Shake")
            shakeCheck:SetValue(shakeEnabled)
            shakeCheck.OnChange = function(_, val) shakeEnabled = val end

            AddSlider("Shake Intensity", 0.2, 5, shakeIntensity, 1, function(v) shakeIntensity = v end)
            AddSlider("Dutch Tilt (deg)", -45, 45, dutchTilt, 0, function(v) dutchTilt = v end)

            local slowMoCheck = vgui.Create("DCheckBoxLabel", scroll)
            slowMoCheck:Dock(TOP)
            slowMoCheck:DockMargin(10, 10, 10, 5)
            slowMoCheck:SetText("Slow-Mo Orbit")
            slowMoCheck:SetValue(slowMoOrbit)
            slowMoCheck.OnChange = function() RunConsoleCommand("cin_cam_toggle_slowmo") end

            AddHeader("AFK Cam")
            local afkCheck = vgui.Create("DCheckBoxLabel", scroll)
            afkCheck:Dock(TOP)
            afkCheck:DockMargin(10, 0, 10, 5)
            afkCheck:SetText("Enable AFK Cam")
            afkCheck:SetValue(afkEnabled)
            afkCheck.OnChange = function(_, val)
                afkEnabled = val
                afkIdleTime = 0
                afkActive = false
            end

            AddSlider("AFK Timeout (sec)", 5, 120, afkTimeout, 0, function(v) afkTimeout = v end)
            AddSlider("AFK Shot Duration (sec)", 3, 20, afkShotDuration, 0, function(v) afkShotDuration = v end)
        end
    })

end
